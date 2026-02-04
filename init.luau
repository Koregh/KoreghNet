--!strict


local KoreghNet = {
	Config = {
		-- Rate Limiting
		MaxRateLimit = 15,
		MaxRateLimitPerChannel = 25,

		-- Payload Limits
		MaxStringLength = 1024,
		MaxPayloadSize = 65536,
		MaxSerializationDepth = 10,

		-- Batching
		BatchLimit = 100,
		MaxQueueSize = 2000,
		QueueWarningThreshold = 500,

		-- Circuit Breaker
		CircuitBreakerThreshold = 50,
		CircuitBreakerResetTime = 60,

		-- Buffer Pool
		BufferPoolSize = 10,
		DefaultBufferSize = 2048,

		-- Misc
		Debug = true,
		MaxDeserializationIterations = 1000,

		-- Internal
		Started = false,
	}
}

local Log = {}

function Log._write(lvl: string, tag: string, msg: string)
	local timestamp = os.date("%H:%M:%S")
	local out = string.format("[%s][%s] KoreghNet::%s > %s", timestamp, lvl, tag, msg)
	if lvl == "ERR" or lvl == "CRIT" then 
		warn(out) 
	else 
		print(out) 
	end
end

function Log.info(tag: string, msg: string) 
	Log._write("INFO", tag, msg) 
end

function Log.warn(tag: string, msg: string) 
	Log._write("WARN", tag, msg) 
end

function Log.error(tag: string, msg: string) 
	Log._write("ERR", tag, msg) 
end

function Log.critical(tag: string, msg: string) 
	Log._write("CRIT", tag, msg) 
end

function Log.debug(tag: string, msg: string)
	if KoreghNet.Config.Debug then
		Log._write("DEBUG", tag, msg)
	end
end

local Metrics = {
	TotalEvents = 0,
	TotalErrors = 0,
	RateLimitHits = 0,
	CircuitBreakerTrips = 0,
	EventsPerSecond = 0,
	EventsThisSecond = 0,
	LastSecondReset = os.clock(),
	PackErrors = 0,
	UnpackErrors = 0,
	ByChannel = {}
}

function Metrics.RecordEvent(eventName: string)
	Metrics.TotalEvents += 1
	Metrics.EventsThisSecond += 1

	if not Metrics.ByChannel[eventName] then
		Metrics.ByChannel[eventName] = { Count = 0, Errors = 0 }
	end
	Metrics.ByChannel[eventName].Count += 1
end

function Metrics.RecordError(eventName: string?)
	Metrics.TotalErrors += 1
	if eventName and Metrics.ByChannel[eventName] then
		Metrics.ByChannel[eventName].Errors += 1
	end
end

function Metrics.Reset()
	local now = os.clock()
	if now - Metrics.LastSecondReset >= 1 then
		Metrics.EventsPerSecond = Metrics.EventsThisSecond
		Metrics.EventsThisSecond = 0
		Metrics.LastSecondReset = now
	end
end

local Types = require(script.SerializerTypes)
local Contracts = require(script.NetworkContracts)
local Guard = require(script.Guard)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local _gateway: RemoteEvent
local _playerRateLimits: {[Player]: {[string]: {Count: number, LastReset: number}}} = {}
local _channels: {[string]: {Callback: (Player?, ...any) -> ()}} = {}
local _middlewares: {(player: Player?, eventName: string, args: {any}) -> boolean} = {}
local _outboundQueue: {{string: any}} = {}
local _lastStatus = ""

-- Circuit Breakers
local CircuitBreakers: {[string]: {
	Errors: number,
	LastError: number,
	Broken: boolean,
	LastReset: number
}} = {}

-- Buffer Pool 
local BufferPool: {buffer} = {}
local BufferPoolLock = false

local function GetBuffer(size: number?): buffer
	local requestedSize = size or KoreghNet.Config.DefaultBufferSize

	if #BufferPool > 0 and not BufferPoolLock then
		local buf = table.remove(BufferPool)
		if buffer.len(buf) >= requestedSize then
			return buf
		end
	end

	return buffer.create(requestedSize)
end

local function ReturnBuffer(buf: buffer)
	if BufferPoolLock then return end

	if #BufferPool < KoreghNet.Config.BufferPoolSize then
		buffer.fill(buf, 0, 0)
		table.insert(BufferPool, buf)
	end
end


function KoreghNet.AddMiddleware(fn: (player: Player?, eventName: string, args: {any}) -> boolean)
	if typeof(fn) ~= "function" then
		Log.error("Middleware", "Middleware should be a function")
		return false
	end
	table.insert(_middlewares, fn)
	Log.debug("Middleware", "Middleware added")
	return true
end

function KoreghNet.RemoveMiddleware(fn: (player: Player?, eventName: string, args: {any}) -> boolean)
	for i, middleware in ipairs(_middlewares) do
		if middleware == fn then
			table.remove(_middlewares, i)
			Log.debug("Middleware", "Removed middleware")
			return true
		end
	end
	return false
end


local function IsRateLimited(player: Player, eventName: string): boolean
	local now = os.clock()
	local contract = Contracts.Get(eventName)
	local limit = if eventName == "__GLOBAL__" 
		then KoreghNet.Config.MaxRateLimit 
		else (contract and contract.Rate or KoreghNet.Config.MaxRateLimitPerChannel)

	if not _playerRateLimits[player] then 
		_playerRateLimits[player] = {} 
	end

	if not _playerRateLimits[player][eventName] then
		_playerRateLimits[player][eventName] = { 
			Count = 0, 
			LastReset = now 
		}
	end

	local data = _playerRateLimits[player][eventName]

	if (now - data.LastReset) >= 1 then
		data.Count = 0
		data.LastReset = now
	end

	data.Count += 1

	if data.Count > limit then
		Metrics.RateLimitHits += 1
		return true
	end

	return false
end

local function CleanupPlayerData(player: Player)
	_playerRateLimits[player] = nil

	for eventName, breaker in pairs(CircuitBreakers) do
		if breaker.LastPlayer == player then
			breaker.LastPlayer = nil
		end
	end

	Log.debug("Cleanup", `Player {player.Name} data cleared`)
end

local function _writeAny(b: buffer, cur: number, val: any): number
	local t = typeof(val)
	local h = Types.Handlers[t]

	if h then
		buffer.writeu8(b, cur, h.Id)
		local success, bytesWritten = pcall(h.Write, b, cur + 1, val, _writeAny)
		if success then
			return 1 + bytesWritten
		else
			Log.error("Serialization", `Error writing type {t}: {bytesWritten}`)
			return 0
		end
	end

	Log.warn("Serialization", `Type not supported: {t}`)
	return 0
end

local function _readAny(b: buffer, cur: number): (any, number)
	if cur >= buffer.len(b) then
		return nil, 0
	end

	local id = buffer.readu8(b, cur)
	local h = Types.Handlers[id]

	if h then
		local success, val, size = pcall(h.Read, b, cur + 1, _readAny)
		if success then
			return val, 1 + size
		else
			Log.error("Deserialization", `Error reading ID type {id}: {val}`)
			return nil, 1
		end
	end

	return nil, 1
end

local function sanitize(val: any, depth: number?, seen: {[any]: boolean}?): any
	local d = depth or 0
	local s = seen or {}
	local typ = typeof(val)

	if d > KoreghNet.Config.MaxSerializationDepth then 
		Log.warn("Sanitize", "Maximum depth reached")
		return nil 
	end

	if typ == "string" then
		if #val > KoreghNet.Config.MaxStringLength then 
			return string.sub(val, 1, KoreghNet.Config.MaxStringLength) 
		end
		return val

	elseif typ == "number" then
		-- Replace NaN and infinities with zero
		if val ~= val or val == math.huge or val == -math.huge then 
			return 0 
		end
		return val

	elseif typ == "table" then
		-- Protection against circular references
		if s[val] then 
			Log.debug("Sanitize", "Circular reference detected")
			return nil 
		end

		s[val] = true
		local newTable = {}

		for k, v in pairs(val) do 
			local sanitizedKey = sanitize(k, d + 1, s)
			local sanitizedVal = sanitize(v, d + 1, s)
			if sanitizedKey ~= nil then
				newTable[sanitizedKey] = sanitizedVal
			end
		end

		return newTable

	elseif typ == "boolean" or typ == "nil" then
		return val
	else
		return val
	end
end


local function ShouldBreakCircuit(eventName: string): boolean
	local breaker = CircuitBreakers[eventName]

	if not breaker then
		CircuitBreakers[eventName] = { 
			Errors = 0, 
			LastError = 0, 
			Broken = false,
			LastReset = os.clock()
		}
		return false
	end

	if breaker.Broken then
		local timeSinceError = os.clock() - breaker.LastError

		if timeSinceError > KoreghNet.Config.CircuitBreakerResetTime then
			breaker.Broken = false
			breaker.Errors = 0
			breaker.LastReset = os.clock()
			Log.info("Circuit", `Channel {eventName} restored after {math.floor(timeSinceError)}s`)
			return false
		else
			return true
		end
	end

	return false
end

local function RecordCircuitError(eventName: string)
	local breaker = CircuitBreakers[eventName]
	if not breaker then return end

	breaker.Errors += 1
	breaker.LastError = os.clock()

	if breaker.Errors >= KoreghNet.Config.CircuitBreakerThreshold then
		breaker.Broken = true
		Metrics.CircuitBreakerTrips += 1
		Log.critical("Circuit", `Circuit breaker OPEN for {eventName} ({breaker.Errors} errors)`)
	end
end

local function RecordCircuitSuccess(eventName: string)
	local breaker = CircuitBreakers[eventName]
	if not breaker then return end

	if breaker.Errors > 0 then
		breaker.Errors = math.max(0, breaker.Errors - 1)
	end
end

function KoreghNet.Pack(...: any): any
	local args = {...}

	local estimatedSize = #args * 64
	estimatedSize = math.min(estimatedSize, KoreghNet.Config.MaxPayloadSize)

	local temp = GetBuffer(estimatedSize)
	local cursor = 0
	local success = true

	for i, val in ipairs(args) do
		local safeVal = sanitize(val)
		local size = _writeAny(temp, cursor, safeVal)

		if size == 0 then
			Log.warn("Pack", `Failed to serialize argument {i} (type: {typeof(val)})`)
			success = false
			break
		end

		if (cursor + size) > KoreghNet.Config.MaxPayloadSize then 
			Log.warn("Pack", `Payload exceeded limit in arg {i}`)
			success = false
			break
		end

		cursor += size
	end

	if not success then
		Metrics.PackErrors += 1
		ReturnBuffer(temp)

		Log.warn("Pack", "Using table fallback")
		local fallbackArgs = {}
		for j, v in ipairs(args) do 
			fallbackArgs[j] = sanitize(v) 
		end
		return fallbackArgs
	end
	
	local final = buffer.create(cursor)
	buffer.copy(final, 0, temp, 0, cursor)
	ReturnBuffer(temp)

	return final
end

function KoreghNet.Unpack(payload: any): {any}
	if typeof(payload) ~= "buffer" then 
		return (typeof(payload) == "table" and payload) or {} 
	end

	local payloadLen = buffer.len(payload)

	if payloadLen > KoreghNet.Config.MaxPayloadSize then
		Log.error("Unpack", `Buffer exceeded MaxPayloadSize: {payloadLen} bytes`)
		Metrics.UnpackErrors += 1
		return {} 
	end

	local args = {}
	local cursor = 0
	local iterations = 0

	while cursor < payloadLen do
		iterations += 1

		-- Proteção contra loop infinito
		if iterations > KoreghNet.Config.MaxDeserializationIterations then
			Log.error("Unpack", "Maximum iterations reached in deserialization")
			Metrics.UnpackErrors += 1
			break
		end

		local val, size = _readAny(payload, cursor)

		if size == 0 then
			Log.error("Unpack", `Zero size returned at position {cursor}`)
			break
		end

		table.insert(args, val)
		cursor += size
	end

	return args
end


function KoreghNet.GetHealth()
	local queueSize = #_outboundQueue
	local errorRate = Metrics.TotalErrors / math.max(1, Metrics.TotalEvents)
	local status = "HEALTHY"
	local issues = {}

	-- Queue size check
	if queueSize > KoreghNet.Config.QueueWarningThreshold then 
		status = "DEGRADED"
		table.insert(issues, `Queue: {queueSize}`) 
	end

	-- Error rate check
	if errorRate > 0.05 then 
		status = "DEGRADED"
		table.insert(issues, `Errors: {math.floor(errorRate * 100)}%`) 
	end

	-- Critical thresholds
	if queueSize > KoreghNet.Config.MaxQueueSize or errorRate > 0.1 then 
		status = "CRITICAL" 
	end

	-- Circuit breaker check
	local brokenCircuits = 0
	for _, breaker in pairs(CircuitBreakers) do
		if breaker.Broken then
			brokenCircuits += 1
		end
	end

	if brokenCircuits > 0 then
		status = "DEGRADED"
		table.insert(issues, `Circuits: {brokenCircuits} open`)
	end

	return {
		Status = status,
		Healthy = status == "HEALTHY",
		Issues = issues,
		Metrics = { 
			QueueSize = queueSize, 
			EventsPerSecond = Metrics.EventsPerSecond, 
			ErrorRate = errorRate,
			BrokenCircuits = brokenCircuits
		}
	}
end

function KoreghNet.GetMetrics()
	return {
		TotalEvents = Metrics.TotalEvents,
		EventsPerSecond = Metrics.EventsPerSecond,
		ErrorRate = Metrics.TotalErrors / math.max(1, Metrics.TotalEvents),
		RateLimitHits = Metrics.RateLimitHits,
		CircuitBreakerTrips = Metrics.CircuitBreakerTrips,
		PackErrors = Metrics.PackErrors,
		UnpackErrors = Metrics.UnpackErrors,
		QueueSize = #_outboundQueue,
		ByChannel = Metrics.ByChannel
	}
end

function KoreghNet.GetChannelMetrics(eventName: string)
	return Metrics.ByChannel[eventName] or { Count = 0, Errors = 0 }
end


function KoreghNet.LogEvent(eventName: string, player: Player?, err: string, args: {any})
	Metrics.RecordError(eventName)

	local safeArgs = sanitize(args)
	local logPayload = {
		Timestamp = os.time(),
		Channel = eventName,
		Player = player and player.Name or "N/A",
		UserId = player and player.UserId or 0,
		Error = err,
		Args = safeArgs,
	}

	local success, encoded = pcall(HttpService.JSONEncode, HttpService, logPayload)
	if success then
		Log.warn("EventError", encoded)
	else
		Log.error("EventError", `Failed to serialize log: {encoded}`)
	end
end


function KoreghNet.Send(eventName: string, ...: any)
	if not KoreghNet.Config.Started then
		Log.error("API", "KoreghNet.Start() must be called before Send()")
		return
	end

	if typeof(eventName) ~= "string" or #eventName == 0 then
		Log.error("API", "eventName must be a non-empty string")
		return
	end

	local payload = KoreghNet.Pack(...)
	table.insert(_outboundQueue, {eventName, payload})

	if #_outboundQueue > KoreghNet.Config.QueueWarningThreshold then
		Log.warn("Queue", `Queue size: {#_outboundQueue}`)
	end
end

function KoreghNet.RegisterChannel(eventName: string, callback: (Player?, ...any) -> ()): boolean
	if typeof(eventName) ~= "string" or #eventName == 0 then
		Log.error("API", "eventName must be a non-empty string")
		return false
	end

	if typeof(callback) ~= "function" then
		Log.error("API", "callback must be a function")
		return false
	end

	if _channels[eventName] then
		Log.warn("Channel", `Channel already registered: {eventName}`)
		return false
	end

	_channels[eventName] = { Callback = callback }
	Log.debug("Channel", `Registered channel: {eventName}`)
	return true
end

function KoreghNet.UnregisterChannel(eventName: string): boolean
	if _channels[eventName] then
		_channels[eventName] = nil
		Log.debug("Channel", `Channel removed: {eventName}`)
		return true
	end
	return false
end


function KoreghNet._onEvent(player: Player?, eventName: string, payload: any)
	local ch = _channels[eventName]
	if not ch then
		Log.debug("Event", `Unregistered channel: {eventName}`)
		return
	end

	if player and IsRateLimited(player, eventName) then 
		if KoreghNet.Config.Debug then 
			Log.warn("RateLimit", `Player {player.Name} exceeded limit on {eventName}`) 
		end
		return 
	end

	local args = KoreghNet.Unpack(payload)

	for _, middleware in ipairs(_middlewares) do
		local ok, result = pcall(middleware, player, eventName, args)
		if not ok then
			Log.error("Middleware", `Error: {result}`)
			return
		end
		if result == false then
			Log.debug("Middleware", `Blocked: {eventName}`)
			return
		end
	end

	local contract = Contracts.Get(eventName)
	if contract and contract.Schema then
		local success, result, err = pcall(contract.Schema, args)

		if not success then
			KoreghNet.LogEvent(eventName, player, "Schema Crash: " .. tostring(result), args)
			return
		end

		if not result then
			KoreghNet.LogEvent(eventName, player, err or "Schema Validation Failed", args)
			return
		end
	end

	Metrics.RecordEvent(eventName)

	if ShouldBreakCircuit(eventName) then
		Log.warn("Circuit", `Event blocked by circuit breaker: {eventName}`)
		return
	end

	task.spawn(function()
		local success, err = pcall(ch.Callback, player, table.unpack(args))

		if not success then
			KoreghNet.LogEvent(eventName, player, err or "Callback Error", args)
			RecordCircuitError(eventName)
		else
			RecordCircuitSuccess(eventName)
		end
	end)
end

function KoreghNet.Start()
	if KoreghNet.Config.Started then 
		Log.warn("Lifecycle", "KoreghNet has already been started")
		return 
	end

	KoreghNet.Config.Started = true

	_gateway = ReplicatedStorage:FindFirstChild("Gateway") or Instance.new("RemoteEvent")
	_gateway.Name = "Gateway"
	_gateway.Parent = ReplicatedStorage

	Log.info("Lifecycle", "Starting network system...")
	Log.info("Config", `BatchLimit: {KoreghNet.Config.BatchLimit}, MaxPayloadSize: {KoreghNet.Config.MaxPayloadSize}`)

	-- Server-side event handling
	if RunService:IsServer() then
		_gateway.OnServerEvent:Connect(function(player, batch)
			if typeof(batch) ~= "table" then 
				Log.warn("Gateway", `Player {player.Name} enviou batch inválido`)
				return 
			end

			if #batch > KoreghNet.Config.BatchLimit then 
				Log.warn("Gateway", `Player {player.Name} excedeu BatchLimit: {#batch}`)
				return 
			end

			if IsRateLimited(player, "__GLOBAL__") then 
				return 
			end
			
			for _, packet in ipairs(batch) do
				if typeof(packet) == "table" and packet[1] and packet[2] then
					KoreghNet._onEvent(player, packet[1], packet[2])
				end
			end
		end)

		Players.PlayerRemoving:Connect(CleanupPlayerData)

		
	else
		-- Client-side event handling
		_gateway.OnClientEvent:Connect(function(batch)
			if typeof(batch) ~= "table" then return end

			for _, packet in ipairs(batch) do 
				if typeof(packet) == "table" and packet[1] and packet[2] then
					KoreghNet._onEvent(nil, packet[1], packet[2]) 
				end
			end
		end)
	end

	RunService.Heartbeat:Connect(function()
		Metrics.Reset()

		-- Update health status
		local health = KoreghNet.GetHealth()
		if health.Status ~= _lastStatus then 
			_lastStatus = health.Status
			ReplicatedStorage:SetAttribute("NetworkStatus", health.Status)

			if health.Status ~= "HEALTHY" then
				Log.warn("Health", `Status: {health.Status} - Issues: {table.concat(health.Issues, ", ")}`)
			end
		end

		-- Process outbound queue
		if #_outboundQueue == 0 then return end

		local batch = {}
		local toProcess = math.min(#_outboundQueue, KoreghNet.Config.BatchLimit)

		for i = 1, toProcess do
			table.insert(batch, table.remove(_outboundQueue, 1))
		end

		if #_outboundQueue > KoreghNet.Config.QueueWarningThreshold then 
			Log.warn("Queue", `Overflow: {#_outboundQueue} items remaining.`) 
		end

		if #_outboundQueue > KoreghNet.Config.MaxQueueSize then
			local dropCount = math.floor(#_outboundQueue * 0.5)
			Log.error("Queue", `CRITICAL: Dropping {dropCount} events to avoid crash.`)

			for i = 1, dropCount do 
				table.remove(_outboundQueue, 1) 
			end
		end

		-- Send batch
		if RunService:IsServer() then 
			_gateway:FireAllClients(batch) 
		else 
			_gateway:FireServer(batch) 
		end
	end)

	Log.info("Lifecycle", "System started successfully!")
end

function KoreghNet.Stop()
	if not KoreghNet.Config.Started then return end

	KoreghNet.Config.Started = false

	_playerRateLimits = {}
	_channels = {}
	_middlewares = {}
	_outboundQueue = {}
	CircuitBreakers = {}

	BufferPoolLock = true
	BufferPool = {}

	Log.info("Lifecycle", "System stopped")
end

return KoreghNet
