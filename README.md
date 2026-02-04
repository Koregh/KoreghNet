> [!WARNING]
> This library is in early development and it is not intended to be used for large productions.

# KoreghNet

**Networking system with type-safe validation, rate limiting, circuit breakers, and binary serialization.**

[![Roblox](https://img.shields.io/badge/Roblox-Compatible-00A2FF?style=for-the-badge\&logo=roblox)](https://www.roblox.com)
[![Luau](https://img.shields.io/badge/Luau-Type--safe-00A2FF?style=for-the-badge)](https://luau-lang.org/)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

---

## Installation

**Roblox Model:** Insert `KoreghNet` into `ReplicatedStorage`

**Wally:**

```toml
[dependencies]
KoreghNet = "koregh/koreghnet@1.0.0"
```

**Manual:** Copy the `KoreghNet` folder to `ReplicatedStorage`

---

## Quickstart

### Server

```lua
local Net = require(game.ReplicatedStorage.KoreghNet)
local Contracts = require(game.ReplicatedStorage.KoreghNet.NetworkContracts)
local Guard = require(game.ReplicatedStorage.KoreghNet.Guard)

Contracts.Add("DamagePlayer", {
    Rate = 10,
    Schema = function(args)
        return Guard.Check(args, {
            [1] = Guard.Number,
            [2] = Guard.Vector3,
            [3] = Guard.Instance("Part")
        })
    end
})

Net.Start()

Net.RegisterChannel("DamagePlayer", function(player, damage, position, part)
    local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
    if humanoid then humanoid:TakeDamage(damage) end
end)
```

### Client

```lua
local Net = require(game.ReplicatedStorage.KoreghNet)
Net.Start()

Net.Send("DamagePlayer", 25, workspace.Dummy.Head.Position, workspace.Dummy.Head)
```

---

## Core Concepts

* **Channels:** Named events for network communication.
* **Network Contracts:** Define rate limits and validation for each channel.
* **Guard System:** Type-safe validation with basic and advanced rules.
* **Binary Serialization:** Fast, buffer-based serialization (strings, numbers, booleans, Vector3, CFrame, Color3, arrays, dictionaries).
* **Rate Limiting & Circuit Breakers:** Automatic spam and error protection.

---

## API Essentials

* `Net.Start()` → Initialize the system
* `Net.Send(eventName, ...)` → Send event
* `Net.Invoke(eventName, timeout, ...)` → Send a request and return a Promise.
* `Net.RegisterChannel(eventName, callback)` → Receive events
* `Contracts.Add(channelName, config)` → Add a network contract
* `Guard.Check(data, schema)` → Validate data
* `Net.GetHealth()` → Monitor queue sizes, error rates, and active circuit breakers

---

## Performance

* Up to 10x faster than JSON
* Automatic buffer reuse
* Event batching
* Low latency (<16ms)

---

## FAQ

* **Can I send Instances?** → Only references (paths), not full objects.
* **Rate limits:** → Both global and per-player.
* **Circuit breaker triggered?** → Events are dropped for X seconds.
