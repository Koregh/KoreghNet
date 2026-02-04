--!strict 

local SerializerTypes = {}

export type Handler = {
	Id: number,
	Name: string,
	Write: (b: buffer, cur: number, val: any, writeAny: any) -> number,
	Read: (b: buffer, cur: number, readAny: any) -> (any, number)
}

local Config = {
	MaxStringLength = 65535, -- uint16 max
	MaxTableSize = 65535,    -- uint16 max
	MaxDictionarySize = 1024,
	ValidateOnWrite = true,
	ValidateOnRead = true,
}

local Handlers: {[string | number]: Handler} = {}
local NextId = 1

local function ValidateNumber(v: number): boolean
	return v == v and v ~= math.huge and v ~= -math.huge
end

local function ValidateString(v: string): boolean
	return #v <= Config.MaxStringLength
end

local function ValidateBuffer(b: buffer, cur: number, size: number): boolean
	return cur >= 0 and cur + size <= buffer.len(b)
end

local function RegisterHandler(name: string, write: any, read: any): number
	local id = NextId
	NextId += 1

	local handler: Handler = {
		Id = id,
		Name = name,
		Write = write,
		Read = read,
	}

	Handlers[id] = handler
	Handlers[name] = handler

	return id
end

-- NIL (ID: 1)
RegisterHandler("nil",
	function(b, cur, v)
		-- Nil doesn't need data, just the type ID
		return 0
	end,
	function(b, cur)
		return nil, 0
	end
)

-- NUMBER (ID: 2)
RegisterHandler("number",
	function(b, cur, v: number)
		if Config.ValidateOnWrite and not ValidateNumber(v) then
			error(`Invalid number: {v}`)
		end
		buffer.writef64(b, cur, v)
		return 8
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 8) then
			error("Buffer overflow reading number")
		end
		return buffer.readf64(b, cur), 8
	end
)

-- STRING (ID: 3)
RegisterHandler("string",
	function(b, cur, v: string)
		local len = #v

		if Config.ValidateOnWrite and not ValidateString(v) then
			error(`String too long: {len} (max {Config.MaxStringLength})`)
		end

		buffer.writeu16(b, cur, len)
		if len > 0 then
			buffer.writestring(b, cur + 2, v, len)
		end
		return 2 + len
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 2) then
			error("Buffer overflow reading string length")
		end

		local len = buffer.readu16(b, cur)

		if len == 0 then
			return "", 2
		end

		if Config.ValidateOnRead and not ValidateBuffer(b, cur + 2, len) then
			error("Buffer overflow reading string data")
		end

		return buffer.readstring(b, cur + 2, len), 2 + len
	end
)

-- BOOLEAN (ID: 4)
RegisterHandler("boolean",
	function(b, cur, v: boolean)
		buffer.writeu8(b, cur, v and 1 or 0)
		return 1
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 1) then
			error("Buffer overflow reading boolean")
		end
		return buffer.readu8(b, cur) == 1, 1
	end
)

-- VECTOR3 (ID: 5)
RegisterHandler("Vector3",
	function(b, cur, v: Vector3)
		buffer.writef32(b, cur, v.X)
		buffer.writef32(b, cur + 4, v.Y)
		buffer.writef32(b, cur + 8, v.Z)
		return 12
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 12) then
			error("Buffer overflow reading Vector3")
		end
		return Vector3.new(
			buffer.readf32(b, cur),
			buffer.readf32(b, cur + 4),
			buffer.readf32(b, cur + 8)
		), 12
	end
)

-- VECTOR2 (ID: 6)
RegisterHandler("Vector2",
	function(b, cur, v: Vector2)
		buffer.writef32(b, cur, v.X)
		buffer.writef32(b, cur + 4, v.Y)
		return 8
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 8) then
			error("Buffer overflow reading Vector2")
		end
		return Vector2.new(
			buffer.readf32(b, cur),
			buffer.readf32(b, cur + 4)
		), 8
	end
)

-- CFRAME (ID: 7)
RegisterHandler("CFrame",
	function(b, cur, cf: CFrame)
		local comps = {cf:GetComponents()}
		for i = 1, 12 do
			buffer.writef32(b, cur + (i - 1) * 4, comps[i])
		end
		return 48
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 48) then
			error("Buffer overflow reading CFrame")
		end
		local t = {}
		for i = 1, 12 do
			t[i] = buffer.readf32(b, cur + (i - 1) * 4)
		end
		return CFrame.new(table.unpack(t)), 48
	end
)

-- COLOR3 (ID: 8)
RegisterHandler("Color3",
	function(b, cur, c: Color3)
		-- Store as 3 bytes (0-255) for compact size
		buffer.writeu8(b, cur, math.floor(c.R * 255))
		buffer.writeu8(b, cur + 1, math.floor(c.G * 255))
		buffer.writeu8(b, cur + 2, math.floor(c.B * 255))
		return 3
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 3) then
			error("Buffer overflow reading Color3")
		end
		return Color3.new(
			buffer.readu8(b, cur) / 255,
			buffer.readu8(b, cur + 1) / 255,
			buffer.readu8(b, cur + 2) / 255
		), 3
	end
)

-- BRICKCOLOR (ID: 9)
RegisterHandler("BrickColor",
	function(b, cur, bc: BrickColor)
		-- Store as uint16 (Number property)
		buffer.writeu16(b, cur, bc.Number)
		return 2
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 2) then
			error("Buffer overflow reading BrickColor")
		end
		return BrickColor.new(buffer.readu16(b, cur)), 2
	end
)

-- UDIM2 (ID: 10)
RegisterHandler("UDim2",
	function(b, cur, u: UDim2)
		buffer.writef32(b, cur, u.X.Scale)
		buffer.writei32(b, cur + 4, u.X.Offset)
		buffer.writef32(b, cur + 8, u.Y.Scale)
		buffer.writei32(b, cur + 12, u.Y.Offset)
		return 16
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 16) then
			error("Buffer overflow reading UDim2")
		end
		return UDim2.new(
			buffer.readf32(b, cur),
			buffer.readi32(b, cur + 4),
			buffer.readf32(b, cur + 8),
			buffer.readi32(b, cur + 12)
		), 16
	end
)

-- UDIM (ID: 11)
RegisterHandler("UDim",
	function(b, cur, u: UDim)
		buffer.writef32(b, cur, u.Scale)
		buffer.writei32(b, cur + 4, u.Offset)
		return 8
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 8) then
			error("Buffer overflow reading UDim")
		end
		return UDim.new(
			buffer.readf32(b, cur),
			buffer.readi32(b, cur + 4)
		), 8
	end
)

-- ENUMITEM (ID: 12)
RegisterHandler("EnumItem",
	function(b, cur, e: EnumItem)
		-- Store enum type name and value
		local enumType = tostring(e.EnumType)
		local enumValue = e.Value

		-- Write enum type name
		local nameLen = #enumType
		buffer.writeu8(b, cur, nameLen)
		buffer.writestring(b, cur + 1, enumType, nameLen)

		-- Write enum value
		buffer.writeu16(b, cur + 1 + nameLen, enumValue)

		return 1 + nameLen + 2
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 1) then
			error("Buffer overflow reading EnumItem")
		end

		local nameLen = buffer.readu8(b, cur)

		if Config.ValidateOnRead and not ValidateBuffer(b, cur + 1, nameLen + 2) then
			error("Buffer overflow reading EnumItem data")
		end

		local enumType = buffer.readstring(b, cur + 1, nameLen)
		local enumValue = buffer.readu16(b, cur + 1 + nameLen)

		-- Reconstruct EnumItem
		local enum = Enum[enumType]
		if not enum then
			error(`Unknown enum type: {enumType}`)
		end

		return enum:FromValue(enumValue), 1 + nameLen + 2
	end
)

-- TABLE (Array) (ID: 13)
RegisterHandler("table",
	function(b, cur, val: {any}, writeAny)
		local len = #val

		if Config.ValidateOnWrite and len > Config.MaxTableSize then
			error(`Table too large: {len} (max {Config.MaxTableSize})`)
		end

		buffer.writeu16(b, cur, len)
		local total = 2

		for i = 1, len do
			local size = writeAny(b, cur + total, val[i])
			total += size
		end

		return total
	end,
	function(b, cur, readAny)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 2) then
			error("Buffer overflow reading table length")
		end

		local len = buffer.readu16(b, cur)

		if Config.ValidateOnRead and len > Config.MaxTableSize then
			error(`Table too large: {len} (max {Config.MaxTableSize})`)
		end

		local result = {}
		local total = 2

		for i = 1, len do
			local v, size = readAny(b, cur + total)
			result[i] = v
			total += size
		end

		return result, total
	end
)

-- DICTIONARY (ID: 14)
-- For tables with string keys
RegisterHandler("dictionary",
	function(b, cur, val: {[string]: any}, writeAny)
		local keys = {}
		for k in pairs(val) do
			if typeof(k) == "string" then
				table.insert(keys, k)
			end
		end

		local len = #keys

		if Config.ValidateOnWrite and len > Config.MaxDictionarySize then
			error(`Dictionary too large: {len} (max {Config.MaxDictionarySize})`)
		end

		buffer.writeu16(b, cur, len)
		local total = 2

		for _, k in ipairs(keys) do
			-- Write key
			local keyLen = #k
			buffer.writeu8(b, cur + total, keyLen)
			buffer.writestring(b, cur + total + 1, k, keyLen)
			total += 1 + keyLen

			-- Write value
			local size = writeAny(b, cur + total, val[k])
			total += size
		end

		return total
	end,
	function(b, cur, readAny)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 2) then
			error("Buffer overflow reading dictionary length")
		end

		local len = buffer.readu16(b, cur)

		if Config.ValidateOnRead and len > Config.MaxDictionarySize then
			error(`Dictionary too large: {len} (max {Config.MaxDictionarySize})`)
		end

		local result = {}
		local total = 2

		for i = 1, len do
			-- Read key
			if Config.ValidateOnRead and not ValidateBuffer(b, cur + total, 1) then
				error("Buffer overflow reading dictionary key length")
			end

			local keyLen = buffer.readu8(b, cur + total)
			total += 1

			if Config.ValidateOnRead and not ValidateBuffer(b, cur + total, keyLen) then
				error("Buffer overflow reading dictionary key")
			end

			local key = buffer.readstring(b, cur + total, keyLen)
			total += keyLen

			-- Read value
			local value, size = readAny(b, cur + total)
			result[key] = value
			total += size
		end

		return result, total
	end
)

-- INSTANCE (ID: 15)
RegisterHandler("Instance",
	function(b, cur, inst: Instance)
		local path = inst:GetFullName()
		local len = #path

		if Config.ValidateOnWrite and len > Config.MaxStringLength then
			error(`Instance path too long: {len}`)
		end

		buffer.writeu16(b, cur, len)
		buffer.writestring(b, cur + 2, path, len)
		return 2 + len
	end,
	function(b, cur)
		if Config.ValidateOnRead and not ValidateBuffer(b, cur, 2) then
			error("Buffer overflow reading Instance path length")
		end

		local len = buffer.readu16(b, cur)

		if Config.ValidateOnRead and not ValidateBuffer(b, cur + 2, len) then
			error("Buffer overflow reading Instance path")
		end

		local path = buffer.readstring(b, cur + 2, len)

		-- Attempt to resolve path
		local success, result = pcall(function()
			local parts = string.split(path, ".")
			local current = game

			for _, part in ipairs(parts) do
				if part ~= "game" then
					current = current:FindFirstChild(part)
					if not current then
						error(`Failed to resolve path: {path}`)
					end
				end
			end

			return current
		end)

		if not success then
			warn(`Failed to deserialize Instance: {result}`)
			return nil, 2 + len
		end

		return result, 2 + len
	end
)

-- INT8 (ID: 16)
RegisterHandler("int8",
	function(b, cur, v: number)
		buffer.writei8(b, cur, v)
		return 1
	end,
	function(b, cur)
		return buffer.readi8(b, cur), 1
	end
)

-- UINT8 (ID: 17)
RegisterHandler("uint8",
	function(b, cur, v: number)
		buffer.writeu8(b, cur, v)
		return 1
	end,
	function(b, cur)
		return buffer.readu8(b, cur), 1
	end
)

-- INT16 (ID: 18)
RegisterHandler("int16",
	function(b, cur, v: number)
		buffer.writei16(b, cur, v)
		return 2
	end,
	function(b, cur)
		return buffer.readi16(b, cur), 2
	end
)

-- UINT16 (ID: 19)
RegisterHandler("uint16",
	function(b, cur, v: number)
		buffer.writeu16(b, cur, v)
		return 2
	end,
	function(b, cur)
		return buffer.readu16(b, cur), 2
	end
)

-- INT32 (ID: 20)
RegisterHandler("int32",
	function(b, cur, v: number)
		buffer.writei32(b, cur, v)
		return 4
	end,
	function(b, cur)
		return buffer.readi32(b, cur), 4
	end
)

-- UINT32 (ID: 21)
RegisterHandler("uint32",
	function(b, cur, v: number)
		buffer.writeu32(b, cur, v)
		return 4
	end,
	function(b, cur)
		return buffer.readu32(b, cur), 4
	end
)

-- FLOAT32 (ID: 22)
RegisterHandler("float32",
	function(b, cur, v: number)
		buffer.writef32(b, cur, v)
		return 4
	end,
	function(b, cur)
		return buffer.readf32(b, cur), 4
	end
)


SerializerTypes.Handlers = Handlers


function SerializerTypes.GetHandler(nameOrId: string | number): Handler?
	return Handlers[nameOrId]
end

function SerializerTypes.IsSupported(typeName: string): boolean
	return Handlers[typeName] ~= nil
end

function SerializerTypes.ListTypes(): {string}
	local types = {}
	for key in pairs(Handlers) do
		if typeof(key) == "string" then
			table.insert(types, key)
		end
	end
	table.sort(types)
	return types
end

function SerializerTypes.GetStats(): {
	TotalHandlers: number,
	SupportedTypes: {string}
	}
	return {
		TotalHandlers = NextId - 1,
		SupportedTypes = SerializerTypes.ListTypes(),
	}
end

function SerializerTypes.Configure(options: {
	MaxStringLength: number?,
	MaxTableSize: number?,
	MaxDictionarySize: number?,
	ValidateOnWrite: boolean?,
	ValidateOnRead: boolean?,
	})
	if options.MaxStringLength then
		Config.MaxStringLength = options.MaxStringLength
	end
	if options.MaxTableSize then
		Config.MaxTableSize = options.MaxTableSize
	end
	if options.MaxDictionarySize then
		Config.MaxDictionarySize = options.MaxDictionarySize
	end
	if options.ValidateOnWrite ~= nil then
		Config.ValidateOnWrite = options.ValidateOnWrite
	end
	if options.ValidateOnRead ~= nil then
		Config.ValidateOnRead = options.ValidateOnRead
	end
end

function SerializerTypes.RegisterCustomHandler(
	name: string,
	write: (b: buffer, cur: number, val: any, writeAny: any) -> number,
	read: (b: buffer, cur: number, readAny: any) -> (any, number)
): number
	if Handlers[name] then
		error(`Handler already registered: {name}`)
	end

	return RegisterHandler(name, write, read)
end

function SerializerTypes.EstimateSize(val: any): number
	local t = typeof(val)

	if t == "nil" then return 1 -- Type ID only
	elseif t == "number" then return 9 -- Type ID + f64
	elseif t == "boolean" then return 2 -- Type ID + u8
	elseif t == "string" then return 3 + #val -- Type ID + u16 length + data
	elseif t == "Vector3" then return 13 -- Type ID + 3*f32
	elseif t == "Vector2" then return 9 -- Type ID + 2*f32
	elseif t == "CFrame" then return 49 -- Type ID + 12*f32
	elseif t == "Color3" then return 4 -- Type ID + 3*u8
	elseif t == "UDim2" then return 17 -- Type ID + 4*f32
	elseif t == "table" then
		
		local size = 3 
		for i = 1, math.min(#val, 100) do 
			size += SerializerTypes.EstimateSize(val[i])
		end
		return size
	else
		return 50 
	end
end

return table.freeze(SerializerTypes)
