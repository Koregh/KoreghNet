--!strict

local KoreghNet = {
	Config = {
		-- Rate Limiting
		MaxRateLimit = 15, -- Events per second per player, change only if necessary
		MaxRateLimitPerChannel = 25, -- Adjust if any specific action is being abused.

		-- Payload Limits
		MaxStringLength = 1024, -- Maximum text size, increases if you need to send larger texts.
		MaxPayloadSize = 65536, -- Maximum size of data sent, modify only for larger packets.
		MaxSerializationDepth = 10, -- Depth of tables, increases if using a lot of data.

		-- Batching
		BatchLimit = 100, -- Frame-sent events, scale up for more performance.
		MaxQueueSize = 2000, -- Maximum events in queue, increase if events are being dropped.
		QueueWarningThreshold = 500, -- When it starts warning about a full queue.

		-- Circuit Breaker
		CircuitBreakerThreshold = 50, -- Number of errors before blocking the channel.
		CircuitBreakerResetTime = 60, -- Time to try to reactivate channel after error.

		-- Buffer Pool
		BufferPoolSize = 10, -- Number of buffers reused.
		DefaultBufferSize = 2048, -- Initial buffer size.

		-- Invoke System
		InvokeDefaultTimeout = 10, -- Maximum invoke response time.
		MaxPendingInvokesPerPlayer = 50,  -- Simultaneous summons per player.

		-- Misc
		Debug = true, -- System logs.
		MaxDeserializationIterations = 1000, -- Protection against loops when reading data.

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
	ByChannel = {},
	
	InvokePendingRequests = 0,
	InvokeTimeouts = 0,
	InvokeErrors = 0,
	InvokeSuccesses = 0,
	InvokeRejectedDuplicates = 0, 
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

local Promise = {}
Promise.__index = Promise

export type PromiseStatus = "Pending" | "Resolved" | "Rejected" | "Cancelled"

function Promise.new<T>(executor: (resolve: (value: T) -> (), reject: (error: any) -> ()) -> ()): any
	local self = setmetatable({}, Promise)

	self._status = "Pending" :: PromiseStatus
	self._value = nil
	self._callbacks = {}
	self._errbacks = {}
	self._finallybacks = {}

	local function resolve(value: T)
		if self._status ~= "Pending" then return end

		self._status = "Resolved"
		self._value = value

		for _, callback in ipairs(self._callbacks) do
			task.spawn(callback, value)
		end

		for _, finallyback in ipairs(self._finallybacks) do
			task.spawn(finallyback)
		end
	end

	local function reject(error: any)
		if self._status ~= "Pending" then return end

		self._status = "Rejected"
		self._value = error

		for _, errback in ipairs(self._errbacks) do
			task.spawn(errback, error)
		end

		for _, finallyback in ipairs(self._finallybacks) do
			task.spawn(finallyback)
		end

		if #self._errbacks == 0 then
			warn("[Promise] Unhandled rejection:", error)
		end
	end

	task.spawn(function()
		local success, result = pcall(executor, resolve, reject)
		if not success then
			reject(result)
		end
	end)

	return self
end

function Promise:andThen(onResolved, onRejected)
	return Promise.new(function(resolve, reject)
		local function handleResolved(value)
			if onResolved then
				local success, result = pcall(onResolved, value)
				if success then
					resolve(result)
				else
					reject(result)
				end
			else
				resolve(value)
			end
		end

		local function handleRejected(error)
			if onRejected then
				local success, result = pcall(onRejected, error)
				if success then
					resolve(result)
				else
					reject(result)
				end
			else
				reject(error)
			end
		end

		if self._status == "Resolved" then
			handleResolved(self._value)
		elseif self._status == "Rejected" then
			handleRejected(self._value)
		else
			table.insert(self._callbacks, handleResolved)
			table.insert(self._errbacks, handleRejected)
		end
	end)
end

function Promise:catch(onRejected)
	return self:andThen(nil, onRejected)
end

function Promise:finally(onFinally)
	table.insert(self._finallybacks, onFinally)
	return self
end

function Promise:await(timeout: number?)
	if self._status == "Resolved" then
		return true, self._value
	elseif self._status == "Rejected" then
		return false, self._value
	elseif self._status == "Cancelled" then
		return false, "Cancelled"
	end
	local thread = coroutine.running()
	local isResumed = false

	local timeoutTask
	if timeout then
		timeoutTask = task.delay(timeout, function()
			if not isResumed then
				isResumed = true
				task.spawn(thread, false, "Await timeout")
			end
		end)
	end

	self:finally(function()

		if timeoutTask then task.cancel(timeoutTask) end

		if not isResumed then
			isResumed = true

			if self._status == "Resolved" then
				task.spawn(thread, true, self._value)
			elseif self._status == "Rejected" then
				task.spawn(thread, false, self._value)
			else
				task.spawn(thread, false, "Cancelled")
			end
		end
	end)

	return coroutine.yield()
end

function Promise:cancel()
	if self._status == "Pending" then
		self._status = "Cancelled"

		for _, finallyback in ipairs(self._finallybacks) do
			task.spawn(finallyback)
		end
	end
end

function Promise:getStatus()
	return self._status
end

function Promise.resolve<T>(value: T): any
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

function Promise.reject<T>(error: any): any
	return Promise.new(function(_, reject)
		reject(error)
	end)
end

function Promise.all<T>(promises: {any}): any
	return Promise.new(function(resolve, reject)
		local results = {}
		local completed = 0
		local total = #promises

		if total == 0 then
			resolve({})
			return
		end

		for i, promise in ipairs(promises) do
			promise:andThen(
				function(value)
					results[i] = value
					completed += 1

					if completed == total then
						resolve(results)
					end
				end,
				reject
			)
		end
	end)
end

function Promise.race<T>(promises: {any}): any
	return Promise.new(function(resolve, reject)
		for _, promise in ipairs(promises) do
			promise:andThen(resolve, reject)
		end
	end)
end

function Promise.delay(seconds: number): any
	return Promise.new(function(resolve)
		task.delay(seconds, function()
			resolve(seconds)
		end)
	end)
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
local _queueReadIndex = 1
local _queueWriteIndex = 1

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

-- Invoke System
local _invokeHandlers: {[string]: (Player?, ...any) -> ...any} = {}

local _pendingInvokes: {[string]: {
	Resolve: (any) -> (),
	Reject: (any) -> (),
	Timeout: number,
	TimeoutTask: thread?, 
	PlayerId: number?,
}} = {}

local _invokeCounter = 0
local _playerInvokeCount: {[number]: number} = {} 

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
	
	local playerId = player.UserId
	for requestId, request in pairs(_pendingInvokes) do
		if request.PlayerId == playerId then
			if request.TimeoutTask then
				task.cancel(request.TimeoutTask)
			end

			_pendingInvokes[requestId] = nil
			Metrics.InvokePendingRequests -= 1
			request.Reject("Player disconnected")
		end
	end

	_playerInvokeCount[playerId] = nil

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

	if not h then
		Log.error("Deserialization", `Invalid type ID {id} at position {cur}. Aborting read.`)
		Metrics.UnpackErrors += 1
		return nil, buffer.len(b) - cur
	end

	local success, val, size = pcall(h.Read, b, cur + 1, _readAny)
	if success then
		if size < 0 or size > buffer.len(b) then
			Log.error("Deserialization", `Invalid size {size} returned for type {id}`)
			return nil, buffer.len(b) - cur
		end
		return val, 1 + size
	else
		Log.error("Deserialization", `Error reading ID type {id}: {val}`)
		return nil, 1
	end
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
		if val ~= val or val == math.huge or val == -math.huge then 
			return 0 
		end
		return val

	elseif typ == "table" then
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

		if val == nil and size >= (payloadLen - cursor) then
			Log.error("Unpack", "Corrupted buffer detected, aborting")
			break
		end

		table.insert(args, val)
		cursor += size
	end

	return args
end

local function GenerateInvokeId(playerId: number?): string
	_invokeCounter += 1
	local guid = HttpService:GenerateGUID(false)

	if playerId then
		return `{playerId}_{guid}_{_invokeCounter}`
	else
		return `{guid}_{_invokeCounter}`
	end
end

local function CleanupInvoke(requestId: string, reason: string)
	local request = _pendingInvokes[requestId]
	if not request then return end

	if request.TimeoutTask then
		task.cancel(request.TimeoutTask)
		request.TimeoutTask = nil
	end

	if request.PlayerId then
		_playerInvokeCount[request.PlayerId] = math.max(0, (_playerInvokeCount[request.PlayerId] or 1) - 1)
	end

	_pendingInvokes[requestId] = nil
	Metrics.InvokePendingRequests = math.max(0, Metrics.InvokePendingRequests - 1)

	request.Reject(reason)
end

function KoreghNet.Invoke(eventName: string, timeout: number?, ...: any): any
	local args = {...}

	local playerId: number? = nil
	if RunService:IsClient() then
		local player = Players.LocalPlayer
		if player then
			playerId = player.UserId

			local count = _playerInvokeCount[playerId] or 0
			if count >= KoreghNet.Config.MaxPendingInvokesPerPlayer then
				return Promise.reject(`Too many pending invokes ({count})`)
			end
		end
	end

	local requestId = GenerateInvokeId(playerId)
	local timeoutDuration = timeout or KoreghNet.Config.InvokeDefaultTimeout

	return Promise.new(function(resolve, reject)
		Metrics.InvokePendingRequests += 1

		if playerId then
			_playerInvokeCount[playerId] = (_playerInvokeCount[playerId] or 0) + 1
		end

		local timeoutTask = task.delay(timeoutDuration, function()
			Metrics.InvokeTimeouts += 1
			CleanupInvoke(requestId, `Request timeout after {timeoutDuration}s`)
		end)

		_pendingInvokes[requestId] = {
			Resolve = resolve,
			Reject = reject,
			Timeout = os.clock() + timeoutDuration,
			TimeoutTask = timeoutTask,
			PlayerId = playerId,
		}

		KoreghNet.Send("__INVOKE_REQUEST__", requestId, eventName, table.unpack(args))
	end)
end

function KoreghNet.RegisterInvokeHandler(eventName: string, handler: (Player?, ...any) -> ...any): boolean
	if typeof(eventName) ~= "string" or #eventName == 0 then
		Log.error("Invoke", "eventName must be a non-empty string")
		return false
	end

	if typeof(handler) ~= "function" then
		Log.error("Invoke", "handler must be a function")
		return false
	end

	if _invokeHandlers[eventName] then
		Log.warn("Invoke", `Handler already registered for '{eventName}'`)
		return false
	end

	_invokeHandlers[eventName] = handler
	Log.debug("Invoke", `Registered invoke handler: {eventName}`)
	return true
end

function KoreghNet.UnregisterInvokeHandler(eventName: string)
	_invokeHandlers[eventName] = nil
	Log.debug("Invoke", `Unregistered invoke handler: {eventName}`)
end

local function HandleInvokeRequest(player: Player?, requestId: string, eventName: string, args: {any})
	if player and RunService:IsServer() then
		local expectedPrefix = tostring(player.UserId) .. "_"
		if not string.match(requestId, "^" .. expectedPrefix) then
			Log.warn("Invoke", `Player {player.Name} sent invalid requestId: {requestId}`)
			Metrics.InvokeRejectedDuplicates += 1
			return
		end
	end

	local handler = _invokeHandlers[eventName]

	if not handler then
		KoreghNet.Send("__INVOKE_RESPONSE__", requestId, false, `No handler for '{eventName}'`)
		return
	end

	task.spawn(function()
		local results = table.pack(pcall(handler, player, table.unpack(args)))
		local success = table.remove(results, 1)

		if success then
			KoreghNet.Send("__INVOKE_RESPONSE__", requestId, true, table.unpack(results, 1, results.n))
			Metrics.InvokeSuccesses += 1
		else
			KoreghNet.Send("__INVOKE_RESPONSE__", requestId, false, results[1])
			Metrics.InvokeErrors += 1
		end
	end)
end

local function HandleInvokeResponse(player: Player?, requestId: string, success: boolean, ...)
	local request = _pendingInvokes[requestId]

	if not request then
		Log.warn("Invoke", `Received response for unknown/expired request: {requestId}`)
		return
	end

	if RunService:IsServer() and player then
		Log.warn("Invoke", `Player {player.Name} tried to spoof invoke response`)
		return
	end

	local resolve = request.Resolve
	local reject = request.Reject

	CleanupInvoke(requestId, "Response received")

	local results = table.pack(...)

	if success then
		resolve(table.unpack(results, 1, results.n))
		Metrics.InvokeSuccesses += 1
	else
		reject(results[1])
		Metrics.InvokeErrors += 1
	end
end

local function ValidateConfig()

	local C = KoreghNet.Config

	C.MaxRateLimit = math.max(1, C.MaxRateLimit)
	C.MaxRateLimitPerChannel = math.max(1, C.MaxRateLimitPerChannel)

	C.MaxStringLength = math.clamp(C.MaxStringLength, 1, 10000)
	C.MaxPayloadSize = math.clamp(C.MaxPayloadSize, 256, 1000000)

	C.BatchLimit = math.max(1, C.BatchLimit)
	C.MaxQueueSize = math.max(C.BatchLimit, C.MaxQueueSize)

	C.QueueWarningThreshold = math.clamp(
		C.QueueWarningThreshold,
		1,
		C.MaxQueueSize
	)

	C.BufferPoolSize = math.max(0, C.BufferPoolSize)
	C.DefaultBufferSize = math.max(256, C.DefaultBufferSize)

	C.InvokeDefaultTimeout = math.max(1, C.InvokeDefaultTimeout)
	C.MaxPendingInvokesPerPlayer = math.max(1, C.MaxPendingInvokesPerPlayer)

	C.MaxDeserializationIterations = math.max(100, C.MaxDeserializationIterations)

end

function KoreghNet.GetHealth()
	local queueSize = _queueWriteIndex - _queueReadIndex
	local errorRate = Metrics.TotalErrors / math.max(1, Metrics.TotalEvents)
	local status = "HEALTHY"
	local issues = {}

	if queueSize > KoreghNet.Config.QueueWarningThreshold then 
		status = "DEGRADED"
		table.insert(issues, `Queue: {queueSize}`) 
	end

	if errorRate > 0.05 then 
		status = "DEGRADED"
		table.insert(issues, `Errors: {math.floor(errorRate * 100)}%`) 
	end

	if queueSize > KoreghNet.Config.MaxQueueSize or errorRate > 0.1 then 
		status = "CRITICAL" 
	end

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
			BrokenCircuits = brokenCircuits,
			InvokePendingRequests = Metrics.InvokePendingRequests,
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
		QueueSize = _queueWriteIndex - _queueReadIndex,
		ByChannel = Metrics.ByChannel,
		InvokePendingRequests = Metrics.InvokePendingRequests,
		InvokeTimeouts = Metrics.InvokeTimeouts,
		InvokeErrors = Metrics.InvokeErrors,
		InvokeSuccesses = Metrics.InvokeSuccesses,
		InvokeRejectedDuplicates = Metrics.InvokeRejectedDuplicates,
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

	_outboundQueue[_queueWriteIndex] = {eventName, payload}
	_queueWriteIndex += 1

	local queueSize = _queueWriteIndex - _queueReadIndex
	if queueSize > KoreghNet.Config.QueueWarningThreshold then
		Log.warn("Queue", `Queue size: {queueSize}`)
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
	ValidateConfig()

	_gateway = ReplicatedStorage:FindFirstChild("Gateway") or Instance.new("RemoteEvent")
	_gateway.Name = "Gateway"
	_gateway.Parent = ReplicatedStorage

	Log.info("Lifecycle", "Starting network system...")
	Log.info("Config", `BatchLimit: {KoreghNet.Config.BatchLimit}, MaxPayloadSize: {KoreghNet.Config.MaxPayloadSize}`)

	KoreghNet.RegisterChannel("__INVOKE_REQUEST__", function(player, requestId, eventName, ...)
		HandleInvokeRequest(player, requestId, eventName, {...})
	end)

	KoreghNet.RegisterChannel("__INVOKE_RESPONSE__", function(player, requestId, success, ...)
		HandleInvokeResponse(player, requestId, success, ...)
	end)

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

		local health = KoreghNet.GetHealth()
		if health.Status ~= _lastStatus then 
			_lastStatus = health.Status
			ReplicatedStorage:SetAttribute("NetworkStatus", health.Status)

			if health.Status ~= "HEALTHY" then
				Log.warn("Health", `Status: {health.Status} - Issues: {table.concat(health.Issues, ", ")}`)
			end
		end

		local queueSize = _queueWriteIndex - _queueReadIndex
		if queueSize == 0 then return end

		local batch = {}
		local toProcess = math.min(queueSize, KoreghNet.Config.BatchLimit)

		for i = 0, toProcess - 1 do
			local index = _queueReadIndex + i
			table.insert(batch, _outboundQueue[index])
			_outboundQueue[index] = nil 
		end

		_queueReadIndex += toProcess

		if _queueReadIndex >= _queueWriteIndex then
			_queueReadIndex = 1
			_queueWriteIndex = 1
		end

		queueSize = _queueWriteIndex - _queueReadIndex

		if queueSize > KoreghNet.Config.QueueWarningThreshold then 
			Log.warn("Queue", `Overflow: {queueSize} items remaining.`) 
		end

		if queueSize > KoreghNet.Config.MaxQueueSize then
			local dropped = 0
			local preserved = 0

			for i = _queueWriteIndex - 1, _queueReadIndex, -1 do
				if queueSize - dropped <= KoreghNet.Config.MaxQueueSize then
					break
				end

				local packet = _outboundQueue[i]
				if packet and packet[1] then
					if string.match(packet[1], "^__INVOKE_") then
						preserved += 1
					else
						_outboundQueue[i] = nil
						dropped += 1
					end
				end
			end

			Log.error("Queue", `CRITICAL: Dropped {dropped} non-critical events, preserved {preserved} invoke messages`)
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
	_queueReadIndex = 1
	_queueWriteIndex = 1

	CircuitBreakers = {}
	_invokeHandlers = {}

	for requestId, request in pairs(_pendingInvokes) do
		if request.TimeoutTask then
			task.cancel(request.TimeoutTask)
		end
		request.Reject("System stopped")
	end
	_pendingInvokes = {}
	_playerInvokeCount = {}

	BufferPoolLock = true
	BufferPool = {}

	Log.info("Lifecycle", "System stopped")
end

KoreghNet.Promise = Promise

return KoreghNet
