--[[
	EliteDataStoreService V1.4.0
	
	[by iamnotultra3 a.k.a Elite]
	
	[MIT LICENSE]
	
	--------------------------------------------------------
	What this module does
	--------------------------------------------------------
	- Handles DataStore request limits for you (no more dropped calls)
	- Strong argument checks for safer use
	- Clean IntelliSense support
	- Lightweight and efficient, minimal overhead
	- Exposes the same methods as DataStoreService (and more), but with
	- built-in safety and better reliability

	--------------------------------------------------------
	Why not just use DataStoreService?
	--------------------------------------------------------
	DataStoreService has a few big issues:
	• Easy to hit request limits and lose calls
	• Errors can happen even if your code is correct
	• API surface is bloated and not always dev-friendly

	This module solves those problems by queueing requests, validating inputs,
	and surfacing errors without sandboxing any functionality.

	--------------------------------------------------------
	Notes
	--------------------------------------------------------
	• This module does not do retries or compression
	• Roblox still enforces the 4MB per key size limit
	• The module is battle tested, you do not have to worry about bugs! (if there is any issue pls tell me)
	• A basic understanding of DataStoreService is recommended:
	"https://create.roblox.com/docs/reference/engine/classes/DataStoreService"
	• The module keeps being enhanced in performance and features, there is also an upcoming CloudService module that is an all-in-one datastore solution, which uses EliteDataStoreService as middleware between the module and DataStores
	--------------------------------------------------------
	Best Practices
	--------------------------------------------------------
	• Prioritize Player Saves on Shutdown: During the game:BindToClose() event, set a flag in your saving logic to ensure all remaining player data saves use the prioritize = true argument. This allows player data saves to jump ahead of any lower-priority background tasks in the queue.
	• Check the success Flag: Always capture and check the second return value (success). If it's false, it means the underlying Roblox API call failed (e.g., internal service error, 500 error, etc.). You should log this and potentially revert any game-state changes associated with the failed operation.
	
	--------------------------------------------------------
	Github
	--------------------------------------------------------
	• "https://github.com/Elentium/EliteDataStoreService-REWORK-"
]]
--!strict

local FreeRunnerThread = nil :: thread? -- the free thread variable we will use to then reuse threads when needed

local function AcquireFreeThreadAndCallEventHandler(fn: (...any) -> (), ...: any)
	-- take the free thread and free it only after the function execution is finished
	local Thread = FreeRunnerThread
	FreeRunnerThread = nil
	fn(...)
	FreeRunnerThread = Thread
	Thread = nil
end

local function RunEventHandlerInFreeThread()
	while true do
		AcquireFreeThreadAndCallEventHandler(coroutine.yield())
		-- wait for the coroutine to be resumed
		-- with function and params data to be sent in the `AcquireFreeThreadAndCallEventHandler`
		-- coroutine.yield() returns whatever the coroutine.resume(co, ...) sends so that is how it works
	end
end

-- there were `Defer` and `Spawn` functions before but i later removed the `Defer` function so that is why there is a helper function
local function HelperThreadSpawner(taskfn, fn: (...any) -> (), ...: any)
	-- if there is no Free Thread = create a new one and resume it
	if not FreeRunnerThread then
		FreeRunnerThread = coroutine.create(RunEventHandlerInFreeThread)
		coroutine.resume(FreeRunnerThread :: any)-- start the coroutine loop
	end

	taskfn(FreeRunnerThread :: any, fn, ...)-- we set the type to any to silenece strict type checker
end

local function Spawn(fn: (...any) -> (), ...: any)
	HelperThreadSpawner(task.spawn, fn, ...)
end

local function GetInstanceFromPath(path: string): Instance?
	local current = game
	for segment in string.gmatch(path, "[^%.]+") do
		current = current:FindFirstChild(segment)
		if not current then return nil end
	end
	return current
end

local SignalU do
	local Connection = {}
	Connection.__index = Connection

	function Connection:Disconnect()
		if not self.Connected then return end
		self.Connected = false

		local parent = self.Parent
		if not parent then return end

		-- since the connection is disconnected = connect previous connection with the next one
		-- if the connection is at the head = replace the head with the next connection
		if self.Prev then
			self.Prev.Next = self.Next
		else
			parent.Head = self.Next
		end

		if self.Next then
			self.Next.Prev = self.Prev
		end

		-- cleanup
		self.Next = nil :: any
		self.Prev = nil :: any
		self.Parent = nil :: any
		self.Listener = nil :: any
		-- the :: any is for silencing the strict type checker
	end

	local Signal = {}
	Signal.__index = Signal


	local function CreateSignal<T...>(_, strictcheck: boolean?, ...: T...)
		-- create a new signal object
		local self = setmetatable({}, Signal)
		-- we do `strictcheck == true` to ensure the value is a boolean
		self.StrictCheck = strictcheck == true
		self.Head = nil :: Connection?
		return (self :: any) :: Signal<T...>-- silence the strict type checker with :: any
	end

	function Signal:Connect(fn)
		-- create a connetion object
		local connection = setmetatable({}, Connection)
		connection.Listener = fn
		connection.Connected = true
		connection.Parent = self

		-- since we add connections to the end = the newest added connection should be at the tail
		if self.Tail then
			-- if a tail already existed = set the current tail's `Next` reference to the new connection
			-- set the new connection's `Prev` reference to the current Tail
			-- set the new tail as the new connection
			self.Tail.Next = connection
			connection.Prev = self.Tail
			self.Tail = connection
		else
			-- tail did not exist = instant set
			-- we also set the head as the new connection because if there is no tail = there is no head
			self.Head = connection
			self.Tail = connection
		end

		-- return the connection
		return connection
	end


	function Signal:Once(fn: (...any) -> ())
		-- store the connection variable and disconnect it as soon as the signal is fired
		local conn

		conn = self:Connect(function(...)
			fn(...)
			conn:Disconnect()
		end)

		return conn
	end

	function Signal:ConnectParallel(fn: (...any) -> ())

		if self.StrictCheck then
			-- if the strict check is on = check if the script that uses the module is running under an actor
			-- 2 is the level of how deep to check, the level 1 is the module itself so we do not want this, level 2 is the script that required the module
			-- "s" of debug.info returns a script path like "ServerScriptService.Script"
			local scriptPath = debug.info(coroutine.running(), 2, "s")
			if scriptPath then
				local scriptInstance = GetInstanceFromPath(scriptPath)
				-- check if the script is running under an Actor
				if scriptInstance and scriptInstance:GetActor() == nil then
					warn(`Cannot use ConnectParallel in non-parallel environment ({scriptPath})`)
					return (nil :: any) :: Connection
				end
			end
		end

		return self:Connect(function(...)
			task.desynchronize()
			fn(...)
		end)
	end

	function Signal:Fire(...: any)
		-- simple linked list iteration
		local node = self.Head
		while node do
			if node.Connected then
				node.Listener(...)
			end
			node = node.Next
		end
	end

	function Signal:FireAsync(...: any)
		-- same iteration, but this time we run each listener in a separate thread
		local node = self.Head
		while node do
			if node.Connected then
				Spawn(node.Listener, ...)
			end
			node = node.Next
		end
	end

	function Signal:Wait(): (...any)
		-- yield the current thread until a signal has been fired
		local co = coroutine.running()
		local conn
		conn = self:Connect(function(...)
			conn:Disconnect()
			-- resume the coroutine with the received data
			coroutine.resume(co, ...)
		end)
		return coroutine.yield()
	end

	function Signal:DisconnectAll()
		-- we simply get rid of the head and tail references, and the connections automatically get garbage collected
		self.Head = nil
		self.Tail = nil
	end

	function Signal:Destroy()
		-- fully clear the signal
		self.Head = nil
		self.Tail = nil
		self.StrictCheck = nil :: any
		-- now you cannot call any of the methods since the signal is not affected by the metatable anymore
		setmetatable(self, nil)
	end

	-- Type annotations

	export type Connection = {
		Disconnect: (self: Connection) -> (),
		Connected: boolean,
		Parent: any, -- here we do `any` instead of `Signal` because the strict type checker warns about Recursive type thing
		Next: Connection?,
		Listener: (...any) -> ()
	}

	export type Signal<T...=()> = {
		Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
		Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
		ConnectParallel: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
		Fire: (self: Signal<T...>, T...) -> (),
		FireAsync: (self: Signal<T...>, T...) -> (),
		Wait: (self: Signal<T...>) -> (T...),
		DisconnectAll: (self: Signal<T...>) -> (),
		Destroy: (self: Signal<T...>) -> ()
	}

	SignalU = setmetatable({
		IsSignal = function(object: any)
			return getmetatable(object) == Signal
		end,
	}, {
		__call = CreateSignal -- __call is being triggered whenever we try to call the table as a function
	})
end
---------------------------------------------------------------------------------------------

--== Variables ==--
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local EliteDataStoreService = {}
EliteDataStoreService.TotalRequests = 0

-- we assign those 1, true, nil for type annotations
-- the first false is `StrictModeEnabled`, we do not need strict mode as it only checks the ConnectParallel while we do not use it here
local RequestProcessed = SignalU(false, 1 :: number, true :: boolean, nil :: any)

-- the main processor that handles datastore requests with budget + key rate limiting
local Processor = {
	IterationCycle = 0.75,-- how often should the processor iterate through the queues
	
	-- the main queue, it is being processed the last(first goes DroppedRequests, after that PriorityQueue)
	-- by default, the requests get transfered to the main queue
	Queue = { Head = nil, Tail = nil, Count = 0 },
	-- the second queue, it is being processed before the main queue as the requests here are prioritized
	-- to prioritize a certain request, every EliteDataStore or EliteOrderedDataStore method's last parameter is `Prioritize`
	-- so you just set the last param to true
	-- example:
	--[[
		-- params:
		-- Key: string (in this case: "Scoreplayer1")
		-- Value: any (in this case: 100)
		-- UserIds: { number? }? (in this case: nil)
		-- Options: DataStoreSetOptions? (in this case: nil)
		-- Prioritize: boolean? (in this case: true, since we want to prioritize the request)
		EliteDataStore:SetAsync("Scoreplayer1", 100, nil, nil, true)
	]]
	PriorityQueue = { Head = nil, Tail = nil, Count = 0 },
	-- the third queue, it is being processed the first, but it is rarely having any requests
	-- the only time there are some requests in the queue,
	-- is when after acquiring a key, the budget gets exhausted
	-- since this module design values safety, we do not call the request if there is any safety concerns
	DroppedRequests = { Head = nil, Tail = nil, Count = 0 },
	
	-- the { Head, Tail, Count } structure in the queues is a linked-list implementation
	-- if you want to learn linked lists, then consider watching this video "https://www.youtube.com/watch?v=DTEraIOfoS0"
	
	-- `KeyRegistry` holds per-datastore per-key data for key locking
	-- every key data structure is { CanRead: boolean, CanWrite: boolean, RefCount: number }
	-- CanRead is for stuff like GetAsync, GetVersionAsync, GetVersionAtTimeAsync
	-- if you try to read a key multiple times at the same time, the DataStore will throttle the requests and even error
	-- so the module ensures that there is only 1 per-key read/write operation at a time
	-- the `RefCount` stores how many references exist for the key data,
	-- when the RefCount is 0, it means there is not any read/write operation for the key and it removes the key data to free up memory
	KeyRegistry = {} :: { [DataStore | OrderedDataStore]: {[string]: { CanRead: boolean, CanWrite: boolean, RefCount: number }} },
	-- `KeyWaiters` holds per-datastore per-key per-mode coroutine waiters
	-- as i explained above, if certain key cannot Read or Write and there is an incoming request:
	-- it inserts the request to certain mode coroutine waiters
	-- whenever another request is finished = it resumes the first request in the queue and the chain continues
	-- however there might be an edge case where after we waited for other requests to preform a per-key operation = the budget got exhausted,
	-- so we enqueue the request to the `DroppedRequests` queue so the request gets safely processed in the next IterationCycle
	KeyWaiters = {} :: { [DataStore | OrderedDataStore]: {[string]: { CanRead: { thread? }, CanWrite: { thread? }, ReadWrite: { thread? } }} },
	
	-- Determines whether the main queue is being processed or not
	QueueProcessing = false :: boolean,
	-- Determines whether the priority queue is being processed or not
	PriorityQueueProcessing  = false :: boolean,
	-- Determines whether the dropped requests queue is being processed or not
	DroppedRequestsProcessing = false :: boolean,
	
	-- If this is set to true, it means none of the queues are being processed and the processor is free
	FinishedAll = true :: boolean,
}

-- Stores per-datastore method handlers
-- each handler accepts a RequestInfo table and returns a success, result OR success, err
-- the handlers are called only after all rate validations have passed and the request is safe to call
local Requests = {
	GetAsync = function(RequestInfo)
		local key = RequestInfo.Key
		local datastore = RequestInfo.DataStore
		local getOpts = RequestInfo.ExtraData.Options
		
		local success, result = pcall(datastore.GetAsync, datastore, key, getOpts)
		
		return success, result
	end,
	GetSortedAsync = function(RequestInfo)
		local Ascending = RequestInfo.ExtraData.Ascending
		local PageSize = RequestInfo.ExtraData.PageSize
		local Min = RequestInfo.ExtraData.MinValue
		local Max = RequestInfo.ExtraData.MaxValue
		local DS = RequestInfo.DataStore :: OrderedDataStore
		
		local success, result = pcall(DS.GetSortedAsync, DS, Ascending, PageSize, Min, Max)
		return success, result
	end,
	
	AdvanceToNextPageAsync = function(RequestInfo)
		local DS = RequestInfo.DataStore :: DataStorePages
		
		local success, err = pcall(function()
			DS:AdvanceToNextPageAsync()
		end)
		
		return success, err
	end,
	
	SetAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local value = RequestInfo.ExtraData.Value
		local userIds = RequestInfo.ExtraData.UserIds
		local opts = RequestInfo.ExtraData.Options
		local success, result = pcall(datastore.SetAsync, datastore, key, value, userIds, opts)
		return success, result
	end,

	IncrementAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local delta = RequestInfo.ExtraData.Delta
		local userIds = RequestInfo.ExtraData.UserIds
		local opts = RequestInfo.ExtraData.Options
		local success, result = pcall(datastore.IncrementAsync, datastore, key, delta, userIds, opts)
		return success, result
	end,

	UpdateAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local transform = RequestInfo.ExtraData.TransformFunction
		local userIds = RequestInfo.ExtraData.UserIds
		local opts = RequestInfo.ExtraData.Options
		local success, result = pcall(datastore.UpdateAsync, datastore, key, transform, userIds, opts)
		return success, result
	end,

	RemoveAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local success, result = pcall(datastore.RemoveAsync, datastore, key)
		return success, result
	end,

	GetVersionAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local version = RequestInfo.ExtraData.Version
		local success, result = pcall(datastore.GetVersionAsync, datastore, key, version)
		return success, result
	end,

	GetVersionAtTimeAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local timestamp = RequestInfo.ExtraData.Timestamp
		local success, result = pcall(datastore.GetVersionAtTimeAsync, datastore, key, timestamp)
		return success, result
	end,

	ListVersionsAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local sortDir = RequestInfo.ExtraData.SortDirection
		local pageSize = RequestInfo.ExtraData.PageSize
		local minDate = RequestInfo.ExtraData.MinDate
		local maxDate = RequestInfo.ExtraData.MaxDate
		local success, result = pcall(datastore.ListVersionsAsync, datastore, key, sortDir, pageSize, minDate, maxDate)
		return success, result
	end,
	
	ListKeysAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local prefix = RequestInfo.ExtraData.Prefix
		local pageSize = RequestInfo.ExtraData.PageSize
		local cursor = RequestInfo.ExtraData.Cursor
		local success, pages = pcall(datastore.ListKeysAsync, datastore, prefix, pageSize, cursor)
		return success, pages
	end,

	RemoveVersionAsync = function(RequestInfo)
		local datastore = RequestInfo.DataStore
		local key = RequestInfo.Key
		local version = RequestInfo.ExtraData.Version
		local success, result = pcall(datastore.RemoveVersionAsync, datastore, key, version)
		return success, result
	end,
	ListDataStoresAsync = function(RequestInfo)
		local extraData = RequestInfo.ExtraData
		local prefix = extraData.Prefix
		local pageSize = extraData.PageSize
		local cursor = extraData.Cursor
		
		local success, result = pcall(function()
			return DataStoreService:ListDataStoresAsync(prefix, pageSize, cursor)
		end)
		
		return success, result
	end,

} :: { [string]: (RequestInfo: {[string]: any}) -> (boolean, any) }

--== Helper functions ==--

-- Checks whether the key is valid for write/read/readwrite operation
local function IsKeyValid(Datastore, Key, mode)
	-- if key is not provided = return true as the request does not require any key handling
	if Key == nil then return true end
	
	-- fetch info
	local info = Processor.KeyRegistry[Datastore][Key]
	if not info then
		info = { CanRead = true, CanWrite = true, RefCount = 0 }
		Processor.KeyRegistry[Datastore][Key] = info
		return true
	end
	-- return result
	if mode == "ReadWrite" then
		return info.CanRead and info.CanWrite
	else
		return info[mode]
	end
end

-- safe version of AcquireKeyLock, if a key is not valid for the request, yields until the lock is freed
local function WaitForKeyAndAcquireLock(Datastore, Key, mode)
	-- fetch registry
	local info = Processor.KeyRegistry[Datastore][Key]
	if not info then
		info = { CanRead = true, CanWrite = true, RefCount = 0 }
		Processor.KeyRegistry[Datastore][Key] = info
	end
	
	local currentCoroutine = coroutine.running()
	
	while not IsKeyValid(Datastore, Key, mode) do
		-- if the key is not valid = enqueue the coroutine and yield until the key is available
		Processor.KeyWaiters[Datastore][Key] = Processor.KeyWaiters[Datastore][Key] or { CanRead = {}, CanWrite = {}, ReadWrite = {} }
		table.insert(Processor.KeyWaiters[Datastore][Key][mode], currentCoroutine)
		coroutine.yield()
	end
	
	-- the key is valid = acquire the lock
	info.RefCount += 1
	if mode == "ReadWrite" then
		info.CanRead, info.CanWrite = false, false
	else
		info[mode] = false
	end
end

-- Helper function to clean up empty key's waiters data
local function CleanupKeyWaiters(DataStore, Key)
	-- fetch waiters
	local Waiters = Processor.KeyWaiters[DataStore][Key]
	if Waiters then
		-- iterate through every mode table, if at least one table has a waiting coroutine = do not cleanup
		-- otherwise we just clean up the data
		local AllEmpty = true
		for _, v in pairs(Waiters) do
			if #v ~= 0 then
				AllEmpty = false
				break
			end
		end
		if AllEmpty then
			Processor.KeyWaiters[DataStore][Key] = nil
			Waiters = nil :: any
		end
	end
end

-- Releases the key lock to free up access for another same key-mode requests
local function ReleaseKeyLock(Datastore, Key, mode)
	local info = Processor.KeyRegistry[Datastore][Key]
	-- if the info somehow does not exist = return, since there is nothing to release
	if not info then return end
	
	-- remove the reference count and if its 0 = clean up registry
	info.RefCount -= 1
	if info.RefCount <= 0 then
		Processor.KeyRegistry[Datastore][Key] = nil
	else
		-- otherwise just set CanRead & CanWrite to true
		if mode == "ReadWrite" then
			info.CanRead, info.CanWrite = true, true
		else
			info[mode] = true
		end
	end
	
	-- fetch waiters
	local waiters = (Processor.KeyWaiters[Datastore][Key] or {})[mode] :: { thread }?
	if waiters and #waiters > 0 then
		-- resume the next in queue waiter
		local waitingCo = table.remove(waiters, 1)

		CleanupKeyWaiters(Datastore, Key)

		coroutine.resume(waitingCo :: thread)
	end
end

local function Enqueue(Queue, Request)
	-- Create a new node with the request
	local NewNode = {
		Request = Request,
		Next = nil,
	}

	if Queue.Tail then
		-- If the queue is not empty, attach the new node to the current tail
		Queue.Tail.Next = NewNode
	else
		-- If the queue is empty, this node is both the head and the tail
		Queue.Head = NewNode
	end

	-- Update the tail pointer
	Queue.Tail = NewNode :: any

	-- Increment the count
	Queue.Count = Queue.Count :: number + 1
end

local function Dequeue(Queue): Request?
	if not Queue.Head then
		-- Queue is empty
		return nil
	end

	-- 1. Get the Request from the Head
	local Request = Queue.Head.Request

	-- 2. Move the Head pointer to the next node
	local NewHead = Queue.Head.Next

	-- 3. Clear the reference to aid garbage collection
	Queue.Head.Request = nil
	Queue.Head.Next = nil

	Queue.Head = NewHead :: any

	if not NewHead then
		-- If the new head is nil, the queue is now empty. Reset the Tail too.
		Queue.Tail = nil
	end

	-- 4. Decrement the count (queue size)
	Queue.Count = Queue.Count :: number - 1

	return Request
end

local function GenerateRequestId(): number
	EliteDataStoreService.TotalRequests += 1
	return EliteDataStoreService.TotalRequests
end

local function ProcessRequest(Request)
	Spawn(function()
		if Request.Key then
			-- if the request has key (meaning its key read/write/readwrite) = acquire the key mode
			WaitForKeyAndAcquireLock(Request.DataStore, Request.Key, Request.KeyAccessMode)
		end
		-- Re-check the budget to ensure reliability
		if DataStoreService:GetRequestBudgetForRequestType(Request.RequestType) < 1 then
			-- While we waited for the key, the budget was exhausted, put the request to dropped requests to then process it
			if Request.Key then ReleaseKeyLock(Request.DataStore, Request.Key, Request.KeyAccessMode) end
			
			Enqueue(Processor.DroppedRequests :: any, Request)
			
			return
		end
		-- all validations have passed = safely preform the operation
		local success, result = Requests[Request.RequestName](Request)
		if Request.Key then ReleaseKeyLock(Request.DataStore, Request.Key, Request.KeyAccessMode) end
		-- fire the signal with results
		RequestProcessed:Fire(Request.Id, success, result)
	end)
end

-- First-layer safety
local function IsRequestValid(request)
	local RequestType = request.RequestType
	
	-- 1. Check budget availability
	if DataStoreService:GetRequestBudgetForRequestType(RequestType) <= 0 then return false end
	-- 2. Check key validity if exists
	local Key = request.Key
	local mode = request.KeyAccessMode
	if Key and not IsKeyValid(request.DataStore, Key, mode) then return false end
	-- All validations passed, return success
	return true
end

-- Iterates through a given queue and processes it
local function IterateThrough(Queue, QueueName: string)
	-- if the queue is empty or its already being processed = return
	if Queue.Count < 1 or Processor[QueueName.."Processing"] then return end
	
	-- set it as processing to prevent other calls from processing the queue
	Processor[QueueName.."Processing"] = true
	
	-- fetch initial count
	local InitialCount = Queue.Count

	for i = 1, InitialCount do
		-- the queue is now empty
		if not Queue.Head then break end
		-- fetch the request
		local request = Queue.Head.Request :: Request 
		
		if IsRequestValid(request) then
			-- if the request is valid = remove the node from the queue and start processing the request
			Dequeue(Queue) 
			ProcessRequest(request)
		else
			-- add the request at the bottom of the queue (requeue)
			Dequeue(Queue)
			Enqueue(Queue :: any, request)
		end
	end
	
	-- the loop has finished, we're not processing the queue anymore
	Processor[QueueName.."Processing"] = false
end

local function AreQueuesEmpty()
	return Processor.Queue.Count == 0 and Processor.PriorityQueue.Count == 0
end

local function EnqueueRequestAndWaitForResult(Request: Request, Prioritize: boolean?, Queue: any?)
	local queue = Queue or (Prioritize and Processor.PriorityQueue or Processor.Queue)

	Enqueue(queue :: any, Request)
	Processor.FinishedAll = false
	local conn = nil
	local co = coroutine.running()
	conn = RequestProcessed:Connect(function(id, success, result)
		if id == Request.Id then
			coroutine.resume(co, success, result)
			conn:Disconnect()
			conn = nil :: any
		end
	end)

	return coroutine.yield()
end

local function PreformDatastoreRequest(RequestName: string, DataStore: DataStore?, Key: string?, KeyAccessMode: string?, RequestType: Enum.DataStoreRequestType, ExtraData: {[string]: any}?, Prioritize: boolean?)
	local Request = {
		Id = GenerateRequestId(),
		Key = Key,
		KeyAccessMode = KeyAccessMode,
		DataStore = DataStore,
		ExtraData = ExtraData,
		RequestType = RequestType,
		RequestName = RequestName
	}
	
	-- First check if there is not any requests in queues
	if AreQueuesEmpty() and IsKeyValid(DataStore :: DataStore, Key :: string, KeyAccessMode) then
		-- if there is no requests in the queues and the request is valid = acquire the key if exists
		if Key then WaitForKeyAndAcquireLock(DataStore :: DataStore, Key, KeyAccessMode) end
		local success, result = Requests[Request.RequestName](Request)
		if Key then ReleaseKeyLock(DataStore :: DataStore, Key, KeyAccessMode) end
		return success, result
	else
		-- there are requests in the queue or the request is not valid to process = enqueue
		return EnqueueRequestAndWaitForResult(Request :: any, Prioritize, nil)
	end
end

--== Main loop ==--

local elapsed = 0
local RSConn = RunService.Heartbeat:Connect(function(delta)
	if Processor.FinishedAll then return end
	elapsed += delta
	
	if elapsed >= Processor.IterationCycle then
		elapsed = 0
		-- iterate through every queue
		IterateThrough(Processor.DroppedRequests :: any, "DroppedRequests")
		IterateThrough(Processor.PriorityQueue :: any, "PriorityQueue")
		IterateThrough(Processor.Queue :: any, "Queue")
		if AreQueuesEmpty() then Processor.FinishedAll = true end
	end
end)

--== Module API ==--

local EliteDataStore = {}
EliteDataStore.__index = EliteDataStore

local EliteDataStorePages = {}
EliteDataStorePages.__index = EliteDataStorePages

local function CreateDataStore(Name, Scope, Opts, IsOrderedDS)
	-- create an EliteDataStore object
	local self = setmetatable({}, EliteDataStore)
	self.Name = Name
	self.DS = IsOrderedDS and DataStoreService:GetOrderedDataStore(Name, Scope) or DataStoreService:GetDataStore(Name, Scope, Opts)
	self.Ordered = IsOrderedDS
	
	-- initialize data
	Processor.KeyRegistry[self.DS] = {}
	Processor.KeyWaiters[self.DS] = {}
	
	return self
end

local function CreateEliteDataStorePages(PagesObj)
	local self = setmetatable({}, EliteDataStorePages)
	self.Pages = PagesObj
	
	return self
end

function EliteDataStorePages:GetCurrentPage()
	return self.Pages:GetCurrentPage()
end

function EliteDataStorePages:AdvanceToNextPageAsync(Prioritize: boolean?)
	local success, err = PreformDatastoreRequest("AdvanceToNextPageAsync", self.Pages, nil, nil, Enum.DataStoreRequestType.GetSortedAsync, nil, Prioritize)
	
	return success, err
end

function EliteDataStorePages:IsFinished()
	return self.Pages.IsFinished
end

function EliteDataStoreService:SetIterationCycle(n: number): ()
	Processor.IterationCycle = n
end

function EliteDataStoreService:GetDataStore(DataStoreName: string, Scope: string?, Options: DataStoreOptions?)
	return CreateDataStore(DataStoreName, Scope, Options, false)
end

function EliteDataStoreService:GetGlobalDataStore()
	local self = setmetatable({}, EliteDataStore)
	self.DS = DataStoreService:GetGlobalDataStore()
	return self
end

function EliteDataStoreService:GetOrderedDataStore(DataStoreName: string, Scope: string?)
	return CreateDataStore(DataStoreName, Scope, nil, true)
end

function EliteDataStoreService:ListDataStoresAsync(Prefix: string?, PageSize: number?, Cursor: string?, Prioritize: boolean?)
	local success, result = PreformDatastoreRequest("ListDataStoresAsync", nil, nil, nil, Enum.DataStoreRequestType.ListAsync, { Prefix = Prefix, PageSize = PageSize, Cursor = Cursor }, Prioritize)
	
	local pages = success and CreateEliteDataStorePages(result) or nil
	return pages or result, success
end

function EliteDataStoreService:WaitForAllRequests()
	repeat
		task.wait()
	until Processor.FinishedAll
end

function EliteDataStoreService:GetRequestBudgetForRequestType(RequestType)
	return DataStoreService:GetRequestBudgetForRequestType(RequestType)
end

function EliteDataStoreService:GetQueueSize()
	return Processor.Queue.Count
end

function EliteDataStoreService:GetPriorityQueueSize()
	return Processor.PriorityQueue.Count
end

function EliteDataStoreService:CheckDataStoreAccess(Log)
	local new_state = "NoAccess"
	local printfn = (Log and print or function<T...>(...: T...) end) :: any
	local warnfn = (Log and warn or function<T...>(...: T...) end) :: any

	local status, message = pcall(function()
		-- This will error if current instance has no Studio API access:
		DataStoreService:GetDataStore("____TEST"):SetAsync("____TEST", os.time())
	end)

	local no_internet_access = status == false and string.find(message, "ConnectFail", 1, true) ~= nil

	if no_internet_access == true then
		warnfn(`[{script.Name}]: No internet access - check your network connection`)
	end

	if status == false and
		(string.find(message, "403", 1, true) ~= nil or -- Cannot write to DataStore from studio if API access is not enabled
			string.find(message, "must publish", 1, true) ~= nil or -- Game must be published to access live keys
			no_internet_access == true) then -- No internet access

		new_state = if no_internet_access == true then "NoInternet" else "NoAccess"
		printfn(`[{script.Name}]: Roblox API services unavailable - data will not be saved`)
	else
		new_state = "Access"
		printfn(`[{script.Name}]: Roblox API services available - data will be saved`)
	end
	
	return new_state
end

-- NOTE: the custom DataStoreService must have the same API as roblox DataStoreService, otherwise the module will not work
function EliteDataStoreService:ReplaceDataStoreServiceWithCustomHandler(Handler)
	DataStoreService = Handler
end

function EliteDataStore:CanRead(Key)
	return IsKeyValid(self.DS, Key, "CanRead")
end

function EliteDataStore:CanWrite(Key)
	return IsKeyValid(self.DS, Key, "CanWrite")
end

function EliteDataStore:GetAsync(Key, Options, Prioritize)
	-- Assert
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif Options ~= nil and (typeof(Options) ~= "Instance" or not (Options :: any):IsA("DataStoreGetOptions")) then
		error(`Invalid argument #2, nil or DataStoreGetOptions expected, got {typeof(Options)}`)
	end
	
	local success, result = PreformDatastoreRequest("GetAsync", self.DS, Key, "CanRead", Enum.DataStoreRequestType.GetAsync, {Options = Options}, Prioritize)
	
	return result, success
	-- we return success as a second return value,
	-- because it is more convenient for some people to just do local data = DS:GetAsync(...),
	-- and users that need more reliability can do local data, success = DS:GetAsync(...)
end

function EliteDataStore:GetSortedAsync(Ascending, PageSize, MinValue, MaxValue, Prioritize)
	if not self.Ordered then
		error("Cannot use GetSortedAsync on a non-Ordered DataStore")
	elseif type(Ascending) ~= "boolean" then
		error(`Invalid argument #1 to GetSortedAsync: expected boolean, got {typeof(Ascending)}`)
	elseif type(PageSize) ~= "number" then
		error(`Invalid argument #2 to GetSortedAsync: expected number, got {typeof(PageSize)}`)
	elseif MinValue ~= nil and type(MinValue) ~= "number" then
		error(`Invalid argument #3 to GetSortedAsync: expected nil or number, got {typeof(MinValue)}`)
	elseif MaxValue ~= nil and type(MaxValue) ~= "number" then
		error(`Invalid argument #4 to GetSortedAsync: expected nil or number, got {typeof(MaxValue)}`)
	end

	local success, result = PreformDatastoreRequest(
		"GetSortedAsync",
		self.DS,
		nil,
		nil,
		Enum.DataStoreRequestType.GetSortedAsync,
		{
			Ascending = Ascending,
			PageSize = PageSize,
			MinValue = MinValue,
			MaxValue = MaxValue
		},
		Prioritize
	)

	local ElitePages = success and CreateEliteDataStorePages(result) or nil
	return ElitePages or result, success
end

function EliteDataStore:SetAsync(Key, Value, UserIds, Options, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if UserIds ~= nil and type(UserIds) ~= "table" then
		error(`Invalid argument #3, table expected, got {typeof(UserIds)}`)
	end
	if Options ~= nil and (typeof(Options) ~= "Instance" or not Options:IsA("DataStoreSetOptions")) then
		error(`Invalid argument #4, nil or DataStoreSetOptions expected, got {typeof(Options)}`)
	end

	local requestType = self.Ordered and Enum.DataStoreRequestType.SetIncrementSortedAsync or Enum.DataStoreRequestType.SetIncrementAsync
	local success, result = PreformDatastoreRequest("SetAsync", self.DS, Key, "CanWrite", requestType,
		{Value = Value, UserIds = UserIds, Options = Options}, Prioritize)
	return result, success
end

function EliteDataStore:UpdateAsync(Key, TransformFunction, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if type(TransformFunction) ~= "function" then
		error(`Invalid argument #2, function expected, got {typeof(TransformFunction)}`)
	end

	local success, result = PreformDatastoreRequest("UpdateAsync", self.DS, Key, "ReadWrite",
		Enum.DataStoreRequestType.UpdateAsync, {TransformFunction = TransformFunction}, Prioritize)
	return result, success
end

function EliteDataStore:RemoveAsync(Key, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end

	local requestType = self.Ordered and Enum.DataStoreRequestType.SetIncrementSortedAsync or Enum.DataStoreRequestType.SetIncrementAsync
	local success, result = PreformDatastoreRequest("RemoveAsync", self.DS, Key, "CanWrite",
		requestType, nil, Prioritize)
	return result, success
end

function EliteDataStore:IncrementAsync(Key, Delta, UserIds, Options, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if type(Delta) ~= "number" then
		error(`Invalid argument #2, number expected, got {typeof(Delta)}`)
	end
	if UserIds ~= nil and type(UserIds) ~= "table" then
		error(`Invalid argument #3, table expected, got {typeof(UserIds)}`)
	end
	if Options ~= nil and (typeof(Options) ~= "Instance" or not Options:IsA("DataStoreIncrementOptions")) then
		error(`Invalid argument #4, nil or DataStoreIncrementOptions expected, got {typeof(Options)}`)
	end

	local requestType = self.Ordered and Enum.DataStoreRequestType.SetIncrementSortedAsync or Enum.DataStoreRequestType.SetIncrementAsync
	local success, result = PreformDatastoreRequest("IncrementAsync", self.DS, Key, "CanWrite",
		requestType, {Delta = Delta, UserIds = UserIds, Options = Options}, Prioritize)
	return result, success
end

function EliteDataStore:ListKeysAsync(Prefix, PageSize, Cursor, ExcludeDeleted, Prioritize)
	if Prefix ~= nil and type(Prefix) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Prefix)}`)
	end
	if PageSize ~= nil and type(PageSize) ~= "number" then
		error(`Invalid argument #2, number expected, got {typeof(PageSize)}`)
	end
	if Cursor ~= nil and type(Cursor) ~= "string" then
		error(`Invalid argument #3, string expected, got {typeof(Cursor)}`)
	end
	if ExcludeDeleted ~= nil and type(ExcludeDeleted) ~= "boolean" then
		error(`Invalid argument #4, boolean expected, got {typeof(ExcludeDeleted)}`)
	end

	local success, pages = PreformDatastoreRequest("ListKeysAsync", self.DS, nil, nil,
		Enum.DataStoreRequestType.ListAsync,
		{Prefix = Prefix, PageSize = PageSize, Cursor = Cursor, ExcludeDeleted = ExcludeDeleted},
		Prioritize)
	local ElitePages = pages and CreateEliteDataStorePages(pages)
	return ElitePages, success
end

function EliteDataStore:ListVersionsAsync(Key, SortDirection, MinDate, MaxDate, PageSize, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if SortDirection ~= nil and typeof(SortDirection) ~= "EnumItem" then
		error(`Invalid argument #2, Enum.SortDirection expected, got {typeof(SortDirection)}`)
	end
	if MinDate ~= nil and type(MinDate) ~= "number" then
		error(`Invalid argument #3, number expected, got {typeof(MinDate)}`)
	end
	if MaxDate ~= nil and type(MaxDate) ~= "number" then
		error(`Invalid argument #4, number expected, got {typeof(MaxDate)}`)
	end
	if PageSize ~= nil and type(PageSize) ~= "number" then
		error(`Invalid argument #5, number expected, got {typeof(PageSize)}`)
	end

	local success, pages = PreformDatastoreRequest("ListVersionsAsync", self.DS, Key, "CanRead",
		Enum.DataStoreRequestType.ListAsync,
		{SortDirection = SortDirection, MinDate = MinDate, MaxDate = MaxDate, PageSize = PageSize},
		Prioritize)
	local ElitePages = pages and CreateEliteDataStorePages(pages)
	return ElitePages, success
end

function EliteDataStore:GetVersionAsync(Key, Version, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if type(Version) ~= "string" then
		error(`Invalid argument #2, string expected, got {typeof(Version)}`)
	end

	local success, result = PreformDatastoreRequest("GetVersionAsync", self.DS, Key, "CanRead",
		Enum.DataStoreRequestType.GetVersionAsync, {Version = Version}, Prioritize)
	return result, success
end

function EliteDataStore:GetVersionAtTimeAsync(Key, Timestamp, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if type(Timestamp) ~= "number" then
		error(`Invalid argument #2, number expected, got {typeof(Timestamp)}`)
	end

	local success, result = PreformDatastoreRequest("GetVersionAtTimeAsync", self.DS, Key, "CanRead",
		Enum.DataStoreRequestType.GetVersionAsync, {Timestamp = Timestamp}, Prioritize)
	return result, success
end

function EliteDataStore:RemoveVersionAsync(Key, Version, Prioritize)
	if type(Key) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if type(Version) ~= "string" then
		error(`Invalid argument #2, string expected, got {typeof(Version)}`)
	end

	local success, result = PreformDatastoreRequest("RemoveVersionAsync", self.DS, Key, "CanWrite",
		Enum.DataStoreRequestType.RemoveVersionAsync, {Version = Version}, Prioritize)
	return result, success
end

--== Shutdown Handling ==--
game:BindToClose(function()
	task.wait(2)--small delay for server scripts to handle shutdown
	repeat
		task.wait()
	until Processor.FinishedAll
	
	RSConn:Disconnect()
	RSConn = nil
end)

--== Type Annotations ==--

export type EliteDataStoreService = {
	GetDataStore: (self: EliteDataStoreService, name: string, scope: string?, options: DataStoreOptions?) -> EliteDataStore,
	GetOrderedDataStore: (self: EliteDataStoreService, name: string, scope: string?) -> EliteOrderedDataStore,
	GetGlobalDataStore: (self: EliteDataStoreService) -> EliteDataStore,
	SetIterationCycle: (self: EliteDataStoreService, seconds: number) -> (),
	TotalRequests: number,
	WaitForAllRequests: (self: EliteDataStoreService) -> (),
	GetRequestBudgetForRequestType: (self: EliteDataStoreService, RequestType: Enum.DataStoreRequestType) -> number,
	GetQueueSize: (self: EliteDataStoreService) -> (),
	GetPriorityQueueSize: (self: EliteDataStoreService) -> (),
	CheckDataStoreAccess: (self: EliteDataStoreService, Log: boolean?) -> ("Access" | "NoAccess" | "NoInternet"),
	ReplaceDataStoreServiceWithCustomHandler: (self: EliteDataStoreService, Handler: any) -> (),
	ListDataStoresAsync: (self: EliteDataStoreService, prefix: string?, pagesize: number?, cursor: string?) -> (DataStoreListingPages, boolean)
}

export type EliteDataStore = {
	Name: string,
	GetAsync: (self: EliteDataStore, key: string, options: DataStoreGetOptions?, prioritize: boolean?) -> (any, boolean),
	SetAsync: (self: EliteDataStore, key: string, value: any, userIds: {number}?, options: DataStoreSetOptions?, prioritize: boolean?) -> (any, boolean),
	IncrementAsync: (self: EliteDataStore, key: string, delta: number?, userIds: {number}?, options: DataStoreIncrementOptions?, prioritize: boolean?) -> (any, boolean),
	UpdateAsync: (self: EliteDataStore, key: string, transform: (any) -> any, prioritize: boolean?) -> (any, boolean),
	RemoveAsync: (self: EliteDataStore, key: string, prioritize: boolean?) -> (any, boolean),
	GetVersionAsync: (self: EliteDataStore, key: string, version: string, prioritize: boolean?) -> (any, boolean),
	GetVersionAtTimeAsync: (self: EliteDataStore, key: string, timestamp: number, prioritize: boolean?) -> (any, boolean),
	ListVersionsAsync: (self: EliteDataStore, key: string, sortDirection: Enum.SortDirection, pageSize: number, minDate: number?, maxDate: number?, prioritize: boolean?) -> (EliteDataStorePages, boolean),
	ListKeysAsync: (self: EliteDataStore, Prefix: string?, PageSize: number?, Cursor: string?, Prioritize: boolean?) -> (EliteDataStorePages, boolean),
	RemoveVersionAsync: (self: EliteDataStore, Key: string, Version: string, Prioritize: boolean?) -> (any?, boolean),
	CanRead: (self: EliteDataStoreService, Key: string) -> boolean,
	CanWrite: (self: EliteDataStoreService, Key: string) -> boolean
}

export type EliteOrderedDataStore = {
	Name: string,
	GetSortedAsync: (self: EliteOrderedDataStore, ascending: boolean, pageSize: number, minValue: number?, maxValue: number?, prioritize: boolean?) -> (EliteDataStorePages, boolean),
	SetAsync: (self: EliteOrderedDataStore, key: string, value: number, userIds: {number}?, options: DataStoreSetOptions?, prioritize: boolean?) -> (any, boolean),
	IncrementAsync: (self: EliteOrderedDataStore, key: string, delta: number?, userIds: {number}?, options: DataStoreIncrementOptions?, prioritize: boolean?) -> (any, boolean),
	UpdateAsync: (self: EliteOrderedDataStore, key: string, transform: (any) -> any, prioritize: boolean?) -> (any, boolean),
	RemoveAsync: (self: EliteOrderedDataStore, key: string, prioritize: boolean?) -> (any, boolean),
}

export type EliteDataStorePages = {
	GetCurrentPage: (self: EliteDataStorePages) -> { [string]: any },
	AdvanceToNextPageAsync: (self: EliteDataStorePages, prioritize: boolean?) -> (boolean, any),
	IsFinished: (self: EliteDataStorePages) -> boolean
}

export type Request = {
	RequestName: string,
	RequestType: Enum.DataStoreRequestType,
	DataStore: DataStore | OrderedDataStore | Pages,
	Id: number,
	Key: string?,
	KeyAccessMode: string?,
	ExtraData: {[string]: any}?,
	Prioritize: boolean?,
}


return (EliteDataStoreService :: any) :: EliteDataStoreService
