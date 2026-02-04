--!strict 

local NetworkContracts = {}

export type SchemaValidator = (args: {any}) -> (boolean, string?)

export type ContractConfig = {
	-- Schema validation function (optional)
	Schema: SchemaValidator?,

	-- Rate limit for this channel
	Rate: number,

	-- Optional metadata
	Description: string?,
	Direction: ("ClientToServer" | "ServerToClient" | "Bidirectional")?,
	RequiresAuth: boolean?,
	Priority: number?,
}

local _contracts: {[string]: ContractConfig} = {}

local DEFAULT_CONFIG: ContractConfig = {
	Rate = 25,
	Description = nil,
	Direction = "Bidirectional",
	RequiresAuth = false,
	Priority = 0,
}

local Config = {
	Debug = false,
	MaxChannelNameLength = 64,
	MinRate = 1,
	MaxRate = 1000,
	WarnOnOverride = true,
}

local function Log(level: string, msg: string)
	if not Config.Debug and level == "DEBUG" then return end

	local prefix = "[NetworkContracts]"
	if level == "ERROR" or level == "WARN" then
		warn(`{prefix}[{level}] {msg}`)
	else
		print(`{prefix}[{level}] {msg}`)
	end
end

local function ValidateChannelName(channelName: string): (boolean, string?)
	if typeof(channelName) ~= "string" then
		return false, "channelName must be a string"
	end

	if #channelName == 0 then
		return false, "channelName cannot be empty"
	end

	if #channelName > Config.MaxChannelNameLength then
		return false, `channelName too long (max {Config.MaxChannelNameLength} chars)`
	end

	if string.match(channelName, "[^%w_%-]") then
		return false, "channelName can only contain alphanumeric, underscore, and hyphen"
	end

	return true
end

local function ValidateConfig(config: ContractConfig): (boolean, string?)
	if typeof(config) ~= "table" then
		return false, "config must be a table"
	end

	if config.Rate ~= nil then
		if typeof(config.Rate) ~= "number" then
			return false, "Rate must be a number"
		end

		if config.Rate < Config.MinRate or config.Rate > Config.MaxRate then
			return false, `Rate must be between {Config.MinRate} and {Config.MaxRate}`
		end

		if config.Rate ~= math.floor(config.Rate) then
			return false, "Rate must be an integer"
		end
	end

	if config.Schema ~= nil then
		if typeof(config.Schema) ~= "function" then
			return false, "Schema must be a function"
		end

		local testSuccess = pcall(function()
			local result, err = config.Schema({})
			if typeof(result) ~= "boolean" then
				error("Schema must return boolean as first value")
			end
			if err ~= nil and typeof(err) ~= "string" then
				error("Schema must return string or nil as second value")
			end
		end)

		if not testSuccess then
			return false, "Schema function has invalid signature (must return boolean, string?)"
		end
	end

	if config.Description ~= nil then
		if typeof(config.Description) ~= "string" then
			return false, "Description must be a string"
		end

		if #config.Description > 256 then
			return false, "Description too long (max 256 chars)"
		end
	end

	if config.Direction ~= nil then
		local validDirections = {
			ClientToServer = true,
			ServerToClient = true,
			Bidirectional = true
		}

		if not validDirections[config.Direction] then
			return false, "Direction must be ClientToServer, ServerToClient, or Bidirectional"
		end
	end

	if config.RequiresAuth ~= nil then
		if typeof(config.RequiresAuth) ~= "boolean" then
			return false, "RequiresAuth must be a boolean"
		end
	end

	if config.Priority ~= nil then
		if typeof(config.Priority) ~= "number" then
			return false, "Priority must be a number"
		end

		if config.Priority ~= math.floor(config.Priority) then
			return false, "Priority must be an integer"
		end
	end

	return true
end

local function MergeWithDefaults(config: ContractConfig): ContractConfig
	return {
		Schema = config.Schema,
		Rate = config.Rate or DEFAULT_CONFIG.Rate,
		Description = config.Description,
		Direction = config.Direction or DEFAULT_CONFIG.Direction,
		RequiresAuth = if config.RequiresAuth ~= nil then config.RequiresAuth else DEFAULT_CONFIG.RequiresAuth,
		Priority = config.Priority or DEFAULT_CONFIG.Priority,
	}
end

function NetworkContracts.Add(channelName: string, config: ContractConfig): boolean
	local validName, nameErr = ValidateChannelName(channelName)
	if not validName then
		Log("ERROR", `Failed to add contract for '{channelName}': {nameErr}`)
		return false
	end

	local validConfig, configErr = ValidateConfig(config)
	if not validConfig then
		Log("ERROR", `Failed to add contract for '{channelName}': {configErr}`)
		return false
	end

	if _contracts[channelName] and Config.WarnOnOverride then
		Log("WARN", `Overwriting existing contract for '{channelName}'`)
	end

	_contracts[channelName] = MergeWithDefaults(config)

	Log("DEBUG", `Added contract for '{channelName}' (Rate: {_contracts[channelName].Rate})`)
	return true
end

function NetworkContracts.Get(channelName: string): ContractConfig
	return _contracts[channelName] or DEFAULT_CONFIG
end

function NetworkContracts.Remove(channelName: string): boolean
	if not _contracts[channelName] then
		Log("DEBUG", `Attempted to remove non-existent contract '{channelName}'`)
		return false
	end

	_contracts[channelName] = nil
	Log("DEBUG", `Removed contract for '{channelName}'`)
	return true
end

function NetworkContracts.Has(channelName: string): boolean
	return _contracts[channelName] ~= nil
end

function NetworkContracts.List(): {string}
	local channels = {}
	for name in pairs(_contracts) do
		table.insert(channels, name)
	end
	table.sort(channels)
	return channels
end

function NetworkContracts.GetAll(): {[string]: ContractConfig}
	local copy = {}
	for name, config in pairs(_contracts) do
		copy[name] = table.clone(config)
	end
	return copy
end

function NetworkContracts.Clear()
	local count = 0
	for _ in pairs(_contracts) do
		count += 1
	end

	_contracts = {}
	Log("DEBUG", `Cleared {count} contracts`)
end

function NetworkContracts.Count(): number
	local count = 0
	for _ in pairs(_contracts) do
		count += 1
	end
	return count
end

function NetworkContracts.GetStats(): {
	TotalContracts: number,
	WithSchema: number,
	WithoutSchema: number,
	AverageRate: number,
	MinRate: number,
	MaxRate: number,
	RequireAuth: number,
	}
	local stats = {
		TotalContracts = 0,
		WithSchema = 0,
		WithoutSchema = 0,
		AverageRate = 0,
		MinRate = math.huge,
		MaxRate = 0,
		RequireAuth = 0,
	}

	local totalRate = 0

	for _, config in pairs(_contracts) do
		stats.TotalContracts += 1

		if config.Schema then
			stats.WithSchema += 1
		else
			stats.WithoutSchema += 1
		end

		totalRate += config.Rate
		stats.MinRate = math.min(stats.MinRate, config.Rate)
		stats.MaxRate = math.max(stats.MaxRate, config.Rate)

		if config.RequiresAuth then
			stats.RequireAuth += 1
		end
	end

	if stats.TotalContracts > 0 then
		stats.AverageRate = totalRate / stats.TotalContracts
	end

	if stats.MinRate == math.huge then
		stats.MinRate = 0
	end

	return stats
end

function NetworkContracts.ValidateArgs(channelName: string, args: {any}): (boolean, string?)
	local contract = _contracts[channelName]

	if not contract then
		return true 
	end

	if not contract.Schema then
		return true
	end

	local success, result, err = pcall(contract.Schema, args)

	if not success then
		return false, `Schema validation crashed: {result}`
	end

	return result, err
end

function NetworkContracts.Export(): {[string]: {Rate: number, Description: string?, Direction: string?}}
	local exported = {}

	for name, config in pairs(_contracts) do
		exported[name] = {
			Rate = config.Rate,
			Description = config.Description,
			Direction = config.Direction,
			RequiresAuth = config.RequiresAuth,
			Priority = config.Priority,
			HasSchema = config.Schema ~= nil,
		}
	end

	return exported
end

function NetworkContracts.Configure(options: {
	Debug: boolean?,
	MaxChannelNameLength: number?,
	MinRate: number?,
	MaxRate: number?,
	WarnOnOverride: boolean?,
	})
	if options.Debug ~= nil then
		Config.Debug = options.Debug
	end

	if options.MaxChannelNameLength ~= nil then
		Config.MaxChannelNameLength = options.MaxChannelNameLength
	end

	if options.MinRate ~= nil then
		Config.MinRate = options.MinRate
	end

	if options.MaxRate ~= nil then
		Config.MaxRate = options.MaxRate
	end

	if options.WarnOnOverride ~= nil then
		Config.WarnOnOverride = options.WarnOnOverride
	end

	Log("DEBUG", "Configuration updated")
end


function NetworkContracts.GetDefault(): ContractConfig
	return table.clone(DEFAULT_CONFIG)
end


function NetworkContracts.SetDefault(config: ContractConfig): boolean
	local valid, err = ValidateConfig(config)

	if not valid then
		Log("ERROR", `Failed to set default config: {err}`)
		return false
	end

	DEFAULT_CONFIG = MergeWithDefaults(config)
	Log("DEBUG", `Default config updated (Rate: {DEFAULT_CONFIG.Rate})`)
	return true
end


function NetworkContracts.AddBulk(contracts: {[string]: ContractConfig}): number
	local successCount = 0

	for channelName, config in pairs(contracts) do
		if NetworkContracts.Add(channelName, config) then
			successCount += 1
		end
	end

	Log("DEBUG", `Bulk add: {successCount}/{#contracts} successful`)
	return successCount
end


function NetworkContracts.RemoveBulk(channelNames: {string}): number
	local successCount = 0

	for _, channelName in ipairs(channelNames) do
		if NetworkContracts.Remove(channelName) then
			successCount += 1
		end
	end

	Log("DEBUG", `Bulk remove: {successCount}/{#channelNames} successful`)
	return successCount
end


function NetworkContracts.Filter(
	predicate: (channelName: string, config: ContractConfig) -> boolean
): {[string]: ContractConfig}
	local filtered = {}

	for name, config in pairs(_contracts) do
		if predicate(name, config) then
			filtered[name] = config
		end
	end

	return filtered
end


function NetworkContracts.FindRequiringAuth(): {[string]: ContractConfig}
	return NetworkContracts.Filter(function(_, config)
		return config.RequiresAuth == true
	end)
end


function NetworkContracts.FindByDirection(
	direction: "ClientToServer" | "ServerToClient" | "Bidirectional"
): {[string]: ContractConfig}
	return NetworkContracts.Filter(function(_, config)
		return config.Direction == direction
	end)
end

function NetworkContracts.FindByMinRate(threshold: number): {[string]: ContractConfig}
	return NetworkContracts.Filter(function(_, config)
		return config.Rate >= threshold
	end)
end

return NetworkContracts
