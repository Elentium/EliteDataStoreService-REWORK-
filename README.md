# EliteDataStoreService V1.6.0

**by iamnotultra3 a.k.a Elite** · [Apache 2.0 License](LICENSE)

A powerful and efficient DataStoreService wrapper that handles most pain points for you, leaving you with full yet safe control of data stores.

---

## What this module does

- Handles DataStore request limits for you (no more dropped calls)
- Strong argument checks for safer use
- Clean IntelliSense support
- Lightweight and efficient, minimal overhead
- Exposes the same methods as DataStoreService (and more), with built-in safety and better reliability
- Rich logging

## Why not just use DataStoreService?

DataStoreService has a few big issues:

- Easy to hit request limits and lose calls
- Errors can happen even if your code is correct
- API surface is bloated and not always dev-friendly

This module solves those problems by queueing requests, validating inputs, and surfacing errors without sandboxing any functionality.

## Notes

- Roblox still enforces the 4MB per key size limit.
- The module is battle-tested; if you find any issue (typo, small inconsistency) please report it.
- A basic understanding of [DataStoreService](https://create.roblox.com/docs/reference/engine/classes/DataStoreService) is recommended.
- The module keeps being enhanced; there is also an upcoming CloudService module (all-in-one datastore solution) that uses EliteDataStoreService as middleware.
- After benchmark tests, this module showed almost no difference in performance compared to raw DataStoreService.
- This module is not a full wrapper like ProfileStore—it is a layer of protection against the main downsides of DataStoreService; almost all control remains with you.

## Best Practices

- **Prioritize player saves on shutdown:** In `game:BindToClose()`, ensure remaining player data saves use `prioritize = true` so they jump ahead of lower-priority tasks in the queue.
- **Check the success flag:** Always capture and check the first return value (`success`). If it is `false`, the underlying Roblox API call failed; log it and consider reverting any game-state changes.

## Links

- **GitHub:** [Elentium/EliteDataStoreService-REWORK-](https://github.com/Elentium/EliteDataStoreService-REWORK-)
- **Wally:** `elentium/elitedatastoreservice@1.6.0`

## Changelog

Version history and update notes are in [CHANGELOG.md](CHANGELOG.md).

## Benchmarks (Studio)

**Test 1 — 100 SetAsync spams for the same key**

| Implementation        | Time (s) | Success | Peak memory |
|-----------------------|----------|---------|-------------|
| EliteDataStoreService | 39.42    | 100%    | 198 KB      |
| DataStoreService      | 29.85    | 31%     | 58 KB       |

**Test 2 — 100 GetAsync spams for the same key**

| Implementation        | Time (s) | Success | Peak memory |
|-----------------------|----------|---------|-------------|
| EliteDataStoreService | 2.86     | 100%    | 243 KB      |
| DataStoreService      | 2.88     | 100%    | 121 KB      |

More benchmark tests (including in-Roblox) coming soon.

---

## Code examples

### 1. Average code

```luau
--!strict
local Players = game:GetService("Players")

local EliteDataStoreService = require(path.to.EliteDataStoreService)

local EliteDataStore = EliteDataStoreService:GetGlobalDataStore()

local PlayersData: { [number]: number } = {}

local function OnPlayerAdded(Player: Player): ()
    local DataSuccess, DataResult = EliteDataStore:Get(Player.UserId)
    if not DataSuccess then
        warn(`Failed to load data for player {Player.Name}, error: {DataResult}`)
        Player:Kick("Failed to load your data, please rejoin")
    else
        print(`Loaded data for player {Player.Name}, data: {DataResult}`)
    end

    DataResult = DataResult or 0
    PlayersData[Player.UserId] = DataResult

    local leaderstats: Folder = Instance.new("Folder")
    leaderstats.Name = "leaderstats"
    leaderstats.Parent = Player

    local Coins: IntValue = Instance.new("IntValue")
    Coins.Name = "Coins"
    Coins.Value = DataResult
    Coins.Parent = leaderstats

    Coins:GetPropertyChangedSignal("Value"):Connect(function()
        PlayersData[Player.UserId] = Coins.Value
    end)
end

local function OnPlayerRemoving(Player: Player): ()
    local Data = PlayersData[Player.UserId]
    if not Data then
        warn(`Data for player {Player.Name} not found`)
        return
    end

    PlayersData[Player.UserId] = nil
    local success, result = EliteDataStore:Set(Player.UserId, Data, { Player.UserId })
    if not success then
        warn(`Failed to save data for player {Player.Name}, error: {result}`)
    else
        print(`Saved data for player {Player.Name}, saved data: {result}`)
    end
end

Players.PlayerAdded:Connect(OnPlayerAdded)

Players.PlayerRemoving:Connect(OnPlayerRemoving)


game:BindToClose(function()
    for _, Player in Players:GetPlayers() do
        task.spawn(OnPlayerRemoving, Player)
    end
end)
```


### 2. Leaderboard example

```luau
--!strict
local Players = game:GetService("Players")

local EliteDataStoreService = require(path.to.EliteDataStoreService)

local EliteDataStore = EliteDataStoreService:GetGlobalDataStore()
local LeaderboardStore = EliteDataStoreService:GetOrderedDataStore("GlobalLB")

local PlayersData: { [number]: number } = {}

local function OnPlayerAdded(Player: Player): ()
    local DataSuccess, DataResult = EliteDataStore:Get(Player.UserId)
    if not DataSuccess then
        warn(`Failed to load data for player {Player.Name}, error: {DataResult}`)
        Player:Kick("Failed to load your data, please rejoin")
    else
        print(`Loaded data for player {Player.Name}, data: {DataResult}`)
    end

    DataResult = DataResult or 0
    PlayersData[Player.UserId] = DataResult

    local leaderstats: Folder = Instance.new("Folder")
    leaderstats.Name = "leaderstats"
    leaderstats.Parent = Player

    local Coins: IntValue = Instance.new("IntValue")
    Coins.Name = "Coins"
    Coins.Value = DataResult
    Coins.Parent = leaderstats

    Coins:GetPropertyChangedSignal("Value"):Connect(function()
        PlayersData[Player.UserId] = Coins.Value
    end)
end

local function OnPlayerRemoving(Player: Player): ()
    local Data = PlayersData[Player.UserId]
    if not Data then
        warn(`Data for player {Player.Name} not found`)
        return
    end

    PlayersData[Player.UserId] = nil
    local success, result = EliteDataStore:Set(Player.UserId, Data, { Player.UserId })
    if not success then
        warn(`Failed to save data for player {Player.Name}, error: {result}`)
    else
        print(`Saved data for player {Player.Name}, saved data: {result}`)
    end

    local successLB, resultLB = LeaderboardStore:Set(Player.UserId, Data, { Player.UserId })
    if not successLB then
        warn(`Failed to save leaderboard data for player {Player.Name}, error: {result}`)
    else
        print(`Saved leaderboard data for player {Player.Name}, saved data: {result}`)
    end
end

Players.PlayerAdded:Connect(OnPlayerAdded)

Players.PlayerRemoving:Connect(OnPlayerRemoving)


game:BindToClose(function()
    for _, Player in Players:GetPlayers() do
        task.spawn(OnPlayerRemoving, Player)
    end
end)

while task.wait(300) do
    local LeaderboardPages = LeaderboardStore:GetSorted(false, 50)
    local page = LeaderboardPages:GetCurrentPage()
    while page and #page > 0 do
        for rank, entry in page do
            print(`[{rank}] : {entry.key} : {entry.value}`)
        end

        local success
        success, page = LeaderboardPages:AdvanceToNextPage()
        if not success then
            warn(`Failed to advance to next page, error: {page}`)
            break
        end
    end
end
```

## API

- **EliteDataStoreService:GetDataStore**(DataStoreName: string, Scope: string?, Options: DataStoreOptions?) -> EliteDataStore*
{
    Status: "Non-Yielding",
	
    Description: "Creates an EliteDataStore object based on the given arguments",
	
    Arguments: (
	
        DataStoreName: string - "How the data store should be called",
		
        Scope: string? - "The branch of the DataStore, does not share any data with other scopes, default scope: 'default'",
		
        Options: DataStoreOptions? - "An instance used to enable/disable experimental features and v2 features"
		
    ),
	
    Returns: EliteDataStore - "The elite data store object"
	
},


- **EliteDataStoreService:GetGlobalDataStore() -> EliteDataStore** {

    Status: "Non-Yielding",
	
    Description: "Creates an EliteDataStore object that uses roblox Global DataStore",
	
    Arguments: (),
	
    Returns: EliteDataStore - "The elite data store object"
	
},


- **EliteDataStoreService:GetOrderedDataStore(DataStoreName: string, Scope: string?) -> EliteOrderedDataStore** {

    Status: "Non-Yielding",
	
    Description: "Creates an EliteOrderedDataStore object based on the given arguments",
	
    Arguments: (
	
        DataStoreName: string - "How the data store should be called",
		
        Scope: string? - "The branch of the DataStore, does not share any data with other scopes, default scope: 'default'"
    ),
	
    Returns: EliteOrderedDataStore - "The elite ordered data store object"
	
},


- **EliteDataStoreService:GetRequestBudgetForRequestType(RequestType: Enum.DataStoreRequestType) -> number** {

    Status: "Non-Yielding",
	
    Description: "Works the same as roblox DataStoreService:GetRequestBudgetForRequestType",
	
    Arguments: (
	
        RequestType: Enum.DataStoreRequestType - "The type of request to get the remaining budget for"
		
    ),
	
    Returns: number - "The remaining budget for the given request type"
	
},


- **EliteDataStoreService:ListDataStores(Prefix: string?, PageSize: number?, Cursor: string?, Prioritize: boolean?) -> (boolean, EliteDataStorePages<DataStoreListingPagesEntry>)** {

    Status: "Yielding",
	
    Description: "Creates a query of game DataStores based on the given arguments",
	
    Arguments: (
	
        Prefix: string? - "Prefix to enumerate data stores that start with the given prefix",
		
        PageSize: number? - "Number of items to be returned in each page. If no value is given, the engine sends a default value of 0 to the data store web service, which in turn defaults to 32 items per page",
		
        Cursor: string? - "Cursor to continue iteration",
		
        Prioritize: boolean? - "Whether to prioritize this request in the processing queue"
		
    ),
	
    Returns: (boolean, EliteDataStorePages<DataStoreListingPagesEntry>) - "Success flag and the elite pages object that is based on DataStoreListingPages, or error message if failed"
	
},


- **EliteDataStoreService:SetIterationCycle(seconds: number) -> ()** {

    Status: "Non-Yielding",
	
    Description: "Sets how often the processor iterates through the queues in seconds",
	
    Arguments: (
	
        seconds: number - "The iteration cycle duration"
		
    ),
	
    Returns: () - "Nothing"
	
},


- **EliteDataStoreService:WaitForAllRequests() -> ()** {

    Status: "Yielding",
	
    Description: "Yields until all pending requests in the queues are processed",
	
    Arguments: (),
	
    Returns: () - "Nothing"
	
},


- **EliteDataStoreService:GetQueueSize() -> number** {

    Status: "Non-Yielding",
	
    Description: "Returns the current size of the main queue",
	
    Arguments: (),
	
    Returns: number - "The number of requests in the main queue"
	
},


- **EliteDataStoreService:GetPriorityQueueSize() -> number** {

    Status: "Non-Yielding",
	
    Description: "Returns the current size of the priority queue",
	
    Arguments: (),
	
    Returns: number - "The number of requests in the priority queue"
	
},


- **EliteDataStoreService:CheckDataStoreAccess() -> 'Access' | 'NoAccess' | 'NoInternet'** {

    Status: "Non-Yielding",
	
    Description: "Checks the current access status to DataStoreService, primarily for Studio environments",
  
    Arguments: (),
  
    Returns: 'Access' | 'NoAccess' | 'NoInternet' - "The access status"
  
},


- **EliteDataStoreService:ReplaceDataStoreServiceWithCustomHandler(Handler: typeof(DataStoreService)) -> ()** {

    Status: "Non-Yielding",
	
    Description: "Replaces the internal DataStoreService reference with a custom handler",
	
    Arguments: (
	
        Handler: typeof(DataStoreService) - "The custom DataStoreService-like object"
		
    ),
	
    Returns: () - "Nothing"
  
},


- **EliteDataStoreService:GuardCall(Method: (...any) -> (boolean, any), MaxRetries: number?, RetriesIntermission: number?, ExponentialBackoff: boolean?, ...: any) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Safely calls a method with retry logic on failure",
	
    Arguments: (
	
        Method: (...any) -> (boolean, any) - "The method to call, expected to return success and result",
		
        MaxRetries: number? - "Maximum retry attempts, default: 5",
		
        RetriesIntermission: number? - "Base delay between retries in seconds, default: 1",
		
        ExponentialBackoff: boolean? - "Whether to use exponential backoff for delays, default: true",
		
        ...: any - "Arguments to pass to the method"
		
    ),
	
    Returns: (boolean, any) - "Success flag and result from the method, or error if all retries fail"
},


- **EliteDataStore:CanRead(Key: string | number) -> boolean** {

    Status: "Non-Yielding",
	
    Description: "Checks if the key is currently available for read operations",
	
    Arguments: (
	
        Key: string | number - "The key to check"
		
    ),
	
    Returns: boolean - "Whether the key can be read"
	
},

- **EliteDataStore:CanWrite(Key: string | number) -> boolean** {

    Status: "Non-Yielding",
	
    Description: "Checks if the key is currently available for write operations",
	
    Arguments: (
	
        Key: string | number - "The key to check"
		
    ),

    Returns: boolean - "Whether the key can be written to"
	
},

- **EliteDataStore:Get(Key: string | number, Options: DataStoreGetOptions?, Prioritize: boolean?) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Retrieves the value associated with the key",
	
    Arguments: (
  
        Key: string | number - "The key to retrieve",
		
        Options: DataStoreGetOptions? - "Optional get options",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, any) - "Success flag and the value, or error message if failed"
	
},

- **EliteDataStore:Set(Key: string | number, Value: any, UserIds: {number}?, Options: DataStoreSetOptions?, Prioritize: boolean?) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Sets the value for the key",
	
    Arguments: (
	
        Key: string | number - "The key to set",
		
        Value: any - "The value to store",
		
        UserIds: {number}? - "Optional user IDs for attribution",
		
        Options: DataStoreSetOptions? - "Optional set options",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, any) - "Success flag and the version ID, or error message if failed"
	
},

- **EliteDataStore:Increment(Key: string | number, Delta: number?, UserIds: {number}?, Options: DataStoreIncrementOptions?, Prioritize: boolean?) -> (boolean, number)** {

    Status: "Yielding",
	
    Description: "Increments the numeric value for the key",
	
    Arguments: (
	
        Key: string | number - "The key to increment",
		
        Delta: number? - "The amount to increment by, default: 1",
		
        UserIds: {number}? - "Optional user IDs for attribution",
		
        Options: DataStoreIncrementOptions? - "Optional increment options",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, number) - "Success flag and the new value, or error message if failed"
  
},


- **EliteDataStore:Update(Key: string | number, TransformFunction: (any) -> any, Prioritize: boolean?) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Updates the value for the key using the transform function",
	
    Arguments: (
	
        Key: string | number - "The key to update",
		
        TransformFunction: (any) -> any - "Function that takes current value and returns new value",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, any) - "Success flag and the updated value, or error message if failed"
	
},


- **EliteDataStore:Remove(Key: string | number, Prioritize: boolean?) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Removes the key and its value",
	
    Arguments: (
	
        Key: string | number - "The key to remove",
        Prioritize: boolean? - "Whether to prioritize this request"
    ),
	
    Returns: (boolean, any) - "Success flag and the removed value, or error message if failed"
	
},


- **EliteDataStore:GetVersion(Key: string | number, Version: string, Prioritize: boolean?) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Retrieves a specific version of the key's value",
	
    Arguments: (
	
        Key: string | number - "The key to retrieve",
		
        Version: string - "The version ID",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, any) - "Success flag and the value at that version, or error message if failed"
	
},


- **EliteDataStore:GetVersionAtTime(Key: string | number, Timestamp: number, Prioritize: boolean?) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Retrieves the version of the key's value at a specific timestamp",
	
    Arguments: (
	
        Key: string | number - "The key to retrieve",
		
        Timestamp: number - "The timestamp in Unix milliseconds",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, any) - "Success flag and the value at that time, or error message if failed"
	
},


- **EliteDataStore:ListVersions(Key: string | number, SortDirection: Enum.SortDirection?, MinDate: number?, MaxDate: number?, PageSize: number?, Prioritize: boolean?) -> (boolean, EliteDataStorePages<DataStoreVersionPagesEntry>)** {

    Status: "Yielding",
	
    Description: "Lists versions for the key",
	
    Arguments: (
	
        Key: string | number - "The key to list versions for",
		
        SortDirection: Enum.SortDirection? - "The sort order, default: Descending",
		
        MinDate: number? - "Minimum creation date in Unix milliseconds",
		
        MaxDate: number? - "Maximum creation date in Unix milliseconds",

        PageSize: number? - "Number of items per page",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, EliteDataStorePages<DataStoreVersionPagesEntry>) - "Success flag and the pages object, or error message if failed"
	
},


- **EliteDataStore:ListKeys(Prefix: string?, PageSize: number?, Cursor: string?, ExcludeDeleted: boolean?, Prioritize: boolean?) -> (boolean, EliteDataStorePages<DataStoreKeyPagesEntry>)** {

    Status: "Yielding",
	
    Description: "Lists keys in the DataStore",
	
    Arguments: (
	
        Prefix: string? - "Prefix to filter keys",
		
        PageSize: number? - "Number of items per page",
		
        Cursor: string? - "Cursor for pagination",
		
        ExcludeDeleted: boolean? - "Whether to exclude deleted keys",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, EliteDataStorePages<DataStoreKeyPagesEntry>) - "Success flag and the pages object, or error message if failed"
	
},


- **EliteDataStore:RemoveVersion(Key: string | number, Version: string, Prioritize: boolean?) -> (boolean, any)** {

    Status: "Yielding",
	
    Description: "Removes a specific version of the key",
	
    Arguments: (
	
        Key: string | number - "The key to modify",
		
        Version: string - "The version ID to remove",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, any) - "Success flag, or error message if failed"
  
},


- **EliteOrderedDataStore:GetSorted(Ascending: boolean, PageSize: number, MinValue: number?, MaxValue: number?, Prioritize: boolean?) -> (boolean, EliteDataStorePages<DataStorePagesEntry>)** {

    Status: "Yielding",
	
    Description: "Retrieves a sorted page of keys and values",
	
    Arguments: (
	
        Ascending: boolean - "Whether to sort in ascending order",
		
        PageSize: number - "Number of items per page",
		
        MinValue: number? - "Minimum value filter",
		
        MaxValue: number? - "Maximum value filter",
		
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, EliteDataStorePages<DataStorePagesEntry>) - "Success flag and the pages object, or error message if failed"
	
},


- **EliteDataStorePages:GetCurrentPage() -> {any}** {

    Status: "Non-Yielding",
	
    Description: "Returns the current page of data",
	
    Arguments: (),
	
    Returns: {any} - "Array of page entries"
	
},


- **EliteDataStorePages:AdvanceToNextPage(Prioritize: boolean?) -> (boolean, string?)** {

    Status: "Yielding",
	
    Description: "Advances to the next page",
	
    Arguments: (
	
        Prioritize: boolean? - "Whether to prioritize this request"
		
    ),
	
    Returns: (boolean, string?) - "Success flag and error message if failed"
	
},


- **EliteDataStorePages:IsFinished() -> boolean** {

    Status: "Non-Yielding",
	
    Description: "Checks if there are no more pages",
	
    Arguments: (),
	
    Returns: boolean - "Whether pagination is finished"
	
},

