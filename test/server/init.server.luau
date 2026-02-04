--!strict

local Net = require(game:GetService("ReplicatedStorage").KoreghNet)
local Contracts = require(game:GetService("ReplicatedStorage").KoreghNet.NetworkContracts)
local Guard = require(game:GetService("ReplicatedStorage").KoreghNet.Guard)

Contracts.Add("Debug", {
	Rate = 10,
	Schema = function(args)
		if not Guard.String(args[1]) then
			return false, "Argumento 1 deve ser string"
		end
		
		if not Guard.Number(args[2]) then
			return false, "Argumento 2 deve ser number"
		end
		
		return true
	end
})

Net.Start()

Net.RegisterChannel("Debug", function(player, arg1, arg2)
	warn("Player:", player)
	warn("String:", arg1)
	warn("Number:", arg2)
end)
