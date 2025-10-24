# EliteDataStoreService-REWORK-
An improved and modernized version of my previous module DataStoreEngine.
EliteDataStoreService provides a robust, safe, and high-performance middleware between your scripts and Roblox’s built-in DataStoreService, solving request limit, concurrency, and reliability issues with a fully optimized internal queueing and locking system.

~ Features

- Handles DataStore request limits automatically — no more dropped or lost calls.
- Thread-safe and concurrency-aware — includes key-level read/write locking.
- Strong argument validation for all API calls.
- Lightweight and efficient — minimal overhead, no sandboxing or retry spam.
- Battle-tested with multiple projects and stress-tested under live environments.
- Type-safe — built with full Luau type annotations and IntelliSense support.
- Supports prioritization — queue important saves (like player data) ahead of background tasks.
- Queue visibility and control — get queue sizes and wait for all pending requests to complete.
- Fully mirrors Roblox DataStoreService API, plus adds safety, prioritization, and control tools.

~ Inserting & Using the module
1. Insert EliteDataStoreService.rbxm inside your ReplicatedStorage or ServerScriptService and require it from your server scripts:
 ```lua
  local EliteDataStoreService = require(path.to.EliteDataStoreService)
  ```
2. Basic Usage Example
```lua
  local EliteDataStoreService = require(game.ServerScriptService.EliteDataStoreService)
local PlayerDataStore = EliteDataStoreService:GetDataStore("PlayerData")

game.Players.PlayerAdded:Connect(function(player)
	local key = "Player_" .. player.UserId
	
	-- Fetch data safely
	local data, success = PlayerDataStore:GetAsync(key)
	if not success then
		warn("Failed to load data for " .. player.Name)
	end
	
	-- Save player data when they leave
	player.AncestryChanged:Connect(function(_, parent)
		if not parent then
			local saveData = { Coins = 100, Level = 10 }
			PlayerDataStore:SetAsync(key, saveData)
		end
	end)
end)
```
3. Advanced example - shutdown handling
```lua
game:BindToClose(function()
	for _, player in game.Players:GetPlayers() do
		local key = "Player_" .. player.UserId
		task.spawn(function()
        PlayerDataStore:SetAsync(key, Data[player], nil, nil, true) -- prioritize = true
    end)
	end
end)
