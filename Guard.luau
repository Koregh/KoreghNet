--!strict

local Guard = {}

type Validator = (value: any) -> (boolean, string?)
export type Schema = { [string | number]: Validator | Schema }

local Config = {
	StrictMode = false, 
	MaxDepth = 10,
	CacheValidators = true,
}

local FrameworkLogger: any = nil

local ValidatorCache: {[Schema]: Validator} = {}

function Guard._setLogger(logger: any)
	FrameworkLogger = logger
end

local function Log(level: string, msg: string)
	if FrameworkLogger then
		if level == "ERROR" then
			FrameworkLogger.error("Guard", msg)
		elseif level == "WARN" then
			FrameworkLogger.warn("Guard", msg)
		else
			FrameworkLogger.info("Guard", msg)
		end
	else
		if level == "ERROR" or level == "WARN" then
			warn(`[GUARD_{level}]: {msg}`)
		else
			print(`[GUARD_INFO]: {msg}`)
		end
	end
end

Guard.String = function(v) 
	if typeof(v) ~= "string" then
		return false, `Expected string, got {typeof(v)}`
	end
	return true
end

Guard.Number = function(v)
	if typeof(v) ~= "number" or v ~= v then -- NaN check
		return false, `Expected number, got {typeof(v)}`
	end
	return true
end

Guard.Boolean = function(v)
	if typeof(v) ~= "boolean" then
		return false, `Expected boolean, got {typeof(v)}`
	end
	return true
end

Guard.Table = function(v)
	if typeof(v) ~= "table" then
		return false, `Expected table, got {typeof(v)}`
	end
	return true
end

Guard.Vector3 = function(v)
	if typeof(v) ~= "Vector3" then
		return false, `Expected Vector3, got {typeof(v)}`
	end
	return true
end

Guard.Vector2 = function(v)
	if typeof(v) ~= "Vector2" then
		return false, `Expected Vector2, got {typeof(v)}`
	end
	return true
end

Guard.CFrame = function(v)
	if typeof(v) ~= "CFrame" then
		return false, `Expected CFrame, got {typeof(v)}`
	end
	return true
end

Guard.Color3 = function(v)
	if typeof(v) ~= "Color3" then
		return false, `Expected Color3, got {typeof(v)}`
	end
	return true
end

Guard.Nil = function(v)
	if v ~= nil then
		return false, `Expected nil, got {typeof(v)}`
	end
	return true
end

Guard.Instance = function(className: string?)
	return function(v)
		if typeof(v) ~= "Instance" then
			return false, `Expected Instance, got {typeof(v)}`
		end
		if className and className ~= "Instance" and not v:IsA(className) then
			return false, `Expected {className}, got {v.ClassName}`
		end
		return true
	end
end

Guard.Array = function(validator: Validator)
	return function(v)
		if typeof(v) ~= "table" then
			return false, `Expected array (table), got {typeof(v)}`
		end

		for i, val in ipairs(v) do
			local ok, err = validator(val)
			if not ok then
				return false, `Array[{i}]: {err or "validation failed"}`
			end
		end

		return true
	end
end

Guard.Dictionary = function(keyValidator: Validator, valueValidator: Validator)
	return function(v)
		if typeof(v) ~= "table" then
			return false, `Expected dictionary (table), got {typeof(v)}`
		end

		for key, val in pairs(v) do
			local keyOk, keyErr = keyValidator(key)
			if not keyOk then
				return false, `Dictionary key '{key}': {keyErr or "validation failed"}`
			end

			local valOk, valErr = valueValidator(val)
			if not valOk then
				return false, `Dictionary['{key}']: {valErr or "validation failed"}`
			end
		end

		return true
	end
end

Guard.Pattern = function(pattern: string)
	return function(v)
		if typeof(v) ~= "string" then
			return false, `Expected string, got {typeof(v)}`
		end
		if not string.match(v, pattern) then
			return false, `String doesn't match pattern '{pattern}'`
		end
		return true
	end
end

Guard.Range = function(min: number, max: number)
	return function(v)
		if typeof(v) ~= "number" or v ~= v then
			return false, `Expected number, got {typeof(v)}`
		end
		if v < min or v > max then
			return false, `Number {v} out of range [{min}, {max}]`
		end
		return true
	end
end

Guard.Integer = function(v)
	if typeof(v) ~= "number" or v ~= v then
		return false, `Expected integer, got {typeof(v)}`
	end
	if v ~= math.floor(v) then
		return false, `Expected integer, got float {v}`
	end
	return true
end

Guard.Positive = function(v)
	if typeof(v) ~= "number" or v ~= v then
		return false, `Expected positive number, got {typeof(v)}`
	end
	if v <= 0 then
		return false, `Expected positive number, got {v}`
	end
	return true
end

Guard.StringLength = function(min: number?, max: number?)
	return function(v)
		if typeof(v) ~= "string" then
			return false, `Expected string, got {typeof(v)}`
		end
		local len = #v
		if min and len < min then
			return false, `String too short (min {min}, got {len})`
		end
		if max and len > max then
			return false, `String too long (max {max}, got {len})`
		end
		return true
	end
end

Guard.Enum = function(...: any)
	local validValues = {...}
	return function(v)
		for _, valid in ipairs(validValues) do
			if v == valid then
				return true
			end
		end
		return false, `Value '{v}' not in enum {table.concat(validValues, ", ")}`
	end
end

Guard.Optional = function(validator: Validator)
	return function(v)
		if v == nil then
			return true
		end
		return validator(v)
	end
end

Guard.Union = function(...: Validator)
	local validators = {...}
	return function(v)
		local errors = {}
		for i, validator in ipairs(validators) do
			local ok, err = validator(v)
			if ok then
				return true
			end
			table.insert(errors, err or "unknown error")
		end
		return false, `Union failed: {table.concat(errors, " OR ")}`
	end
end

Guard.Intersection = function(...: Validator)
	local validators = {...}
	return function(v)
		for i, validator in ipairs(validators) do
			local ok, err = validator(v)
			if not ok then
				return false, err
			end
		end
		return true
	end
end

Guard.Custom = function(fn: (value: any) -> (boolean, string?), errorMsg: string?)
	return function(v)
		local ok, err = fn(v)
		if not ok then
			return false, errorMsg or err or "Custom validation failed"
		end
		return true
	end
end

function Guard.Check(data: any, schema: Schema, depth: number?): (boolean, string?)
	local d = depth or 0

	if d > Config.MaxDepth then
		return false, `Max depth {Config.MaxDepth} exceeded`
	end

	if typeof(data) ~= "table" then
		return false, `Data is not a table (got {typeof(data)})`
	end

	for key, validator in pairs(schema) do
		local value = data[key]

		if typeof(validator) == "table" then
			local ok, err = Guard.Check(value, validator :: Schema, d + 1)
			if not ok then
				return false, `[{tostring(key)}].{err}`
			end
		elseif typeof(validator) == "function" then
			local ok, err = (validator :: Validator)(value)
			if not ok then
				return false, `[{tostring(key)}]: {err or "validation failed"}`
			end
		end
	end

	if Config.StrictMode then
		for key in pairs(data) do
			if schema[key] == nil then
				return false, `Unexpected field: {tostring(key)}`
			end
		end
	end

	return true
end

function Guard.Args(...: Validator)
	local validators = {...}
	return function(args: {any}): (boolean, string?)
		if #args < #validators then
			return false, `Expected {#validators} arguments, got {#args}`
		end

		for i, validator in ipairs(validators) do
			local ok, err = validator(args[i])
			if not ok then
				return false, `Arg[{i}]: {err or "validation failed"}`
			end
		end

		return true
	end
end

function Guard.Wrap(schema: Schema | (args: {any}) -> (boolean, string?), callback: (...any) -> (...any))
	return function(...)
		local args = {...}
		local ok, err

		if typeof(schema) == "function" then
			ok, err = schema(args)
		else
			ok, err = Guard.Check(args, schema :: Schema)
		end

		if ok then
			return callback(...)
		else
			local errorMsg = `Validation failed: {err or "Unknown error"}`
			Log("ERROR", errorMsg)
			error(errorMsg, 2)
		end
	end
end

function Guard.Try(schema: Schema | (args: {any}) -> (boolean, string?), callback: (...any) -> (...any))
	return function(...)
		local args = {...}
		local ok, err

		if typeof(schema) == "function" then
			ok, err = schema(args)
		else
			ok, err = Guard.Check(args, schema :: Schema)
		end

		if ok then
			return callback(...)
		else
			Log("WARN", `Validation failed: {err or "Unknown error"}`)
			return nil
		end
	end
end


function Guard.Compile(schema: Schema): Validator
	if Config.CacheValidators and ValidatorCache[schema] then
		return ValidatorCache[schema]
	end

	local validator = function(data: any)
		return Guard.Check(data, schema)
	end

	if Config.CacheValidators then
		ValidatorCache[schema] = validator
	end

	return validator
end

function Guard.GetOrDefault(data: any, validator: Validator, default: any): any
	local ok, err = validator(data)
	if ok then
		return data
	else
		Log("WARN", `Validation failed, using default: {err}`)
		return default
	end
end

function Guard.Assert(value: any, validator: Validator, message: string?)
	local ok, err = validator(value)
	if not ok then
		local msg = message or `Assertion failed: {err}`
		Log("ERROR", msg)
		error(msg, 2)
	end
end

function Guard.ValidateAsync(data: any, schema: Schema): ()
	task.spawn(function()
		local ok, err = Guard.Check(data, schema)
		if not ok then
			Log("WARN", `Async validation failed: {err}`)
		end
	end)
end

function Guard.Configure(options: {
	StrictMode: boolean?,
	MaxDepth: number?,
	CacheValidators: boolean?,
	})
	if options.StrictMode ~= nil then
		Config.StrictMode = options.StrictMode
	end
	if options.MaxDepth ~= nil then
		Config.MaxDepth = options.MaxDepth
	end
	if options.CacheValidators ~= nil then
		Config.CacheValidators = options.CacheValidators
	end

	Log("INFO", "Configuration updated")
end

function Guard.GetConfig()
	return table.clone(Config)
end

function Guard.ClearCache()
	ValidatorCache = {}
	Log("INFO", "Validator cache cleared")
end

function Guard.Describe(validator: Validator): string
	if validator == Guard.String then return "string"
	elseif validator == Guard.Number then return "number"
	elseif validator == Guard.Boolean then return "boolean"
	elseif validator == Guard.Table then return "table"
	elseif validator == Guard.Vector3 then return "Vector3"
	elseif validator == Guard.Integer then return "integer"
	elseif validator == Guard.Positive then return "positive number"
	else return "custom validator"
	end
end

function Guard.Test(value: any, validator: Validator): {
	Valid: boolean,
	Error: string?,
	Type: string,
	ValidatorType: string
	}
	local ok, err = validator(value)
	return {
		Valid = ok,
		Error = err,
		Type = typeof(value),
		ValidatorType = Guard.Describe(validator)
	}
end

return table.freeze(Guard)
