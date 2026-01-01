--[[
	EliteDataStoreService V1.5.0
	
	[by iamnotultra3 a.k.a Elite]
	
	[MIT LICENSE]

	A powerful and efficient DataStoreService wrapper that handles most pain points for you, leaving you with big, yet safe control of data stores
	
	--------------------------------------------------------
	What this module does
	--------------------------------------------------------
	- Handles DataStore request limits for you (no more dropped calls)
	- Strong argument checks for safer use
	- Clean IntelliSense support
	- Lightweight and efficient
	- Exposes the same methods as DataStoreService (and more), but with
	- built-in safety and better reliability
	- minimal overhead
	- good logging

	--------------------------------------------------------
	Why not just use DataStoreService?
	--------------------------------------------------------
	DataStoreService has a few big issues:
	- Easy to hit request limits and lose calls
	- Errors can happen even if your code is correct
	- API surface is bloated and not always dev-friendly

	This module solves those problems by queueing requests, validating inputs,
	and surfacing errors without sandboxing any functionality.

	--------------------------------------------------------
	Notes
	--------------------------------------------------------
	- A basic understanding of DataStoreService is recommended:
	"https://create.roblox.com/docs/reference/engine/classes/DataStoreService"
	- The module keeps being enhanced in performance and features, there is also an upcoming CloudService module that is an all-in-one datastore solution, which uses EliteDataStoreService as middleware between the module and DataStores
	- This module is never meant to be a full wrapper like ProfileStore, its just a layer of protection against most annoying downsides of DataStoreService, all control is given to you
	--------------------------------------------------------
	Best Practices
	--------------------------------------------------------
	- Prioritize Player Saves on Shutdown: During the game:BindToClose() event, set a flag in your saving logic to ensure all remaining player data saves use the prioritize = true argument. This allows player data saves to jump ahead of any lower-priority background tasks in the queue.
	- Check the success Flag: Always capture and check the first return value (success). If it's false, it means the underlying Roblox API call failed (e.g., internal service error, 500 error, etc.). You should log this and potentially revert any game-state changes associated with the failed operation.
	--------------------------------------------------------
	Github
	--------------------------------------------------------
	- "https://github.com/Elentium/EliteDataStoreService-REWORK-"

	--------------------------------------------------------
	Update Logs (starting from V1.5.0)
	--------------------------------------------------------
	
	- New method: GuardCall
	- Improved IntelliSense
	- Added logging & configurations
	- Improved API & comments
	- Added wally support
	- Reduced default iteration cycle to 0.35 seconds
	- Changed key locking sytem(more on that below)
	
	Update notes:
	- All method names are changed (removed redundant Async in the names)
	- Now all data store request methods(like GetAsync) firstly return success, and only then result
	- Update 1.6.0 is coming with even better performance and changes
	
	-- New Key Locking System --
	The new key locking system is very different from the previous one,
	main differences:
	- linear vs smart processing: the old one used linear method (1 read at a time, 1 write at a time)
	which could cause small desynchronizations to reading and writing,
	and recently DataStoreService started allowing concurrent reads, 
	so the old system became really outdated
	- the new system on the other hand allows concurrent reads,
	only if no write is happening and not even a single write request is pending
	and the writes stay linear (however 1 more change is that no write can happen while read is happening)
	this new approach solves a lot of issue, benefits:
	- if a read is incoming while other writes are processing or pending,
	the scripts are likely to read the new saved data from these writes, 
	so this read will keep waiting until all writes are finished
	- if a write is incoming, while read is happening, 
	the scripts are likely to read the previous data since the write arrived after those reads
	so it will yield until all reads are completed
	it prevents more and more reads from flooding the queue by simply incrementing pending writes, which stops all further reads from haappening
	there is one small weakness of the new system:
	- if more and more writes spam requests, the reads will never get to happen
	this is unlikely to happen since in normal environments requests spam almost never happen
	and write budget will be exhausted anyway if spams occur for such a long period
	it is fixable by simply adding PendingReads flag however write is more prioritized than reads
	and might not fit normal environments as good,
	in update V1.6.0 i will think about this and decide which method should i use
	Thanks for reading!

	Useful resources to learn from:
	- linked lists: "https://www.youtube.com/watch?v=DTEraIOfoS0",
	- data stores: [
		beginner: "https://youtu.be/H-cDbjd5-bs?si=UZ1IJfiFhw1_EI6n",
		intermediate: "https://youtu.be/B446FyN1xtc?si=JoK9dPGpF1qva7HG",
		advanced: "https://create.roblox.com/docs/reference/engine/classes/DataStoreService"
	],
	- metatables: "https://youtu.be/bk8UVm-gxBs?si=Kjga1m_VFFPrbeWo"
	
	
	-- Benchmark tests(in studio) --
	Test 1 (100 SetAsync spams for the same key):
		EliteDataStoreService: 39.42210533330217 seconds | 100% success | 198 KB Peak memory usage
		DataStoreService: 29.84927079168847 seconds | 31% success | 58 KB Peak memory usage
	Test 2 (100 GetAsync spams for the same key):
		EliteDataStoreService: 2.8620037916698493 seconds | 100% success | 243 KB Peak memory usage
		DataStoreService: 2.8833942916826345 seconds | 100% success | 121 KB Peak memory usage
		
	more benchmark tests coming soon (in-roblox benchmark included)
]]
--!strict
--!optimize 2
--== Constants ==--
-- 0 = none
-- 1 = only warnings
-- 2 = only warnings & process logs
-- 3 = every log
local LOG_LEVEL: number = 1

-- GuardCall default config
local DEFAULT_MAX_RETRIES: number = 5 -- how many attempts will it make until giving up
local DEFAULT_RETRIES_INTERMISSION: number = 1 -- in seconds
local DEFAULT_EXPONENTIAL_BACKOFF: boolean = true -- if disabled, the intermission will always be n, if disabled, the intermission will be n * attempts

--== Services ==--
local DataStoreService: DataStoreService = game:GetService("DataStoreService")
local RunService: RunService = game:GetService("RunService")

--== Variables ==--
local EliteDataStoreService = {}
EliteDataStoreService.TotalRequests = 0 :: number

-- the main processor that handles datastore requests with budget + key rate limiting
local Processor = {
	IterationCycle = 0.35 :: number, -- how often should the processor iterate through the queues

	-- the main queue, it is being processed the last(first goes DroppedRequests, after that PriorityQueue)
	-- by default, the requests get transferred to the main queue
	Queue = { Head = nil, Tail = nil, Count = 0 } :: Queue,
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
	PriorityQueue = { Head = nil, Tail = nil, Count = 0 } :: Queue,
	-- the third queue, it is being processed the first, but it is rarely having any requests
	-- the only time there are some requests in the queue,
	-- is when a key lock for Write/Read/WriteRead is lost
	-- since this module design values safety, we do not call the request if there is any safety concerns
	DroppedRequests = { Head = nil, Tail = nil, Count = 0 } :: Queue,

	-- the { Head, Tail, Count } structure in the queues is a linked-list implementation
	-- if you want to learn linked lists, then consider watching this video "https://www.youtube.com/watch?v=DTEraIOfoS0"

	-- `KeyRegistry` holds per-datastore per-key data for key locking
	-- every key data structure is { Read: boolean, Write: boolean, RefCount: number }
	-- Read is for stuff like GetAsync, GetVersionAsync, GetVersionAtTimeAsync
	-- if you try to read a key multiple times at the same time, the DataStore will throttle the requests and even error
	-- so the module ensures that there is only 1 per-key read/write operation at a time
	-- the `RefCount` stores how many references exist for the key data,
	-- when the RefCount is 0, it means there is not any read/write operation for the key and it removes the key data to free up memory
	KeyRegistry = {} :: {
		[DataStore | OrderedDataStore]: {
			[string]: { Writing: boolean, ActiveReaders: number, PendingWrites: number, RefCount: number }
				& { [string]: any },
		},
	},
	-- `KeyWaiters` holds per-datastore per-key per-mode coroutine waiters
	-- as i explained above, if certain key cannot Read or Write and there is an incoming request:
	-- it inserts the request to certain mode coroutine waiters
	-- whenever another request is finished = it resumes the first request in the queue and the chain continues
	-- however there might be an edge case where 2 requests of the same key and mode have been called at the same time,
	-- in this case it would be inefficient as i would have to implement confirmation chain
	-- so we just enqueue the request to the `DroppedRequests` queue so the request gets safely processed in the next IterationCycle
	KeyWaiters = {} :: {
		[DataStore | OrderedDataStore]: {
			[string]: {
				Read: { [number]: thread? },
				Write: { [number]: thread? },
			} & { [string]: { thread? } },
		},
	},

	-- Determines whether the main queue is being processed or not
	QueueProcessing = false :: boolean,
	-- Determines whether the priority queue is being processed or not
	PriorityQueueProcessing = false :: boolean,
	-- Determines whether the dropped requests queue is being processed or not
	DroppedRequestsProcessing = false :: boolean,

	-- If this is set to true, it means none of the queues are being processed and the processor is free
	FinishedAll = true :: boolean,
}

-- Used to store EliteDataStore | EliteOrderedDataStore objects, when CreateDataStore called, checks if "{O | N}_{Name}_{Scope}" exists in cache, if it does = returns the cached object
local DatastoresCache = {}

-- Stores per-datastore method handlers
-- each handler accepts a RequestInfo table and returns a success, result OR success, err
-- the handlers are called only after all rate validations have passed and the request is safe to call
local Requests: {
	[string]: (RequestInfo: Request) -> (boolean, any),
} = {
	GetAsync = function(RequestInfo: Request): (boolean, any)
		local key: string = RequestInfo.Key
		local datastore: DataStore | OrderedDataStore = RequestInfo.DataStore
		local getOpts: DataStoreGetOptions? = RequestInfo.ExtraData.Options

		local success: boolean, result: any = pcall(datastore.GetAsync, datastore, key, getOpts)

		return success, result
	end,
	GetSortedAsync = function(RequestInfo: Request): (boolean, DataStorePages)
		local Ascending: boolean = RequestInfo.ExtraData.Ascending
		local PageSize: number = RequestInfo.ExtraData.PageSize
		local Min: number? = RequestInfo.ExtraData.MinValue
		local Max: number? = RequestInfo.ExtraData.MaxValue
		local DS: OrderedDataStore = RequestInfo.DataStore :: OrderedDataStore

		local success: boolean, result: DataStorePages = pcall(DS.GetSortedAsync, DS, Ascending, PageSize, Min, Max)
		return success, result
	end,

	AdvanceToNextPageAsync = function(RequestInfo: Request): (boolean, string?)
		local DS: Pages = RequestInfo.DataStore :: any

		local success: boolean, err: string? = pcall(DS.AdvanceToNextPageAsync, DS)

		return success, err
	end,

	SetAsync = function(RequestInfo: Request): (boolean, any)
		local datastore: DataStore | OrderedDataStore = RequestInfo.DataStore
		local key: string = RequestInfo.Key
		local value: any = RequestInfo.ExtraData.Value
		local userIds: { number }? = RequestInfo.ExtraData.UserIds
		local opts = RequestInfo.ExtraData.Options
		local success: boolean, result: any =
			pcall(datastore.SetAsync, datastore, key, value, userIds :: { any }?, opts)
		return success, result
	end,

	IncrementAsync = function(RequestInfo: Request): (boolean, number)
		local datastore: DataStore | OrderedDataStore = RequestInfo.DataStore
		local key: string = RequestInfo.Key
		local delta: number? = RequestInfo.ExtraData.Delta
		local userIds: { number }? = RequestInfo.ExtraData.UserIds
		local opts: DataStoreIncrementOptions? = RequestInfo.ExtraData.Options :: any
		local success: boolean, result: number = pcall(function()
			return datastore:IncrementAsync(key, delta, userIds :: { any }, opts) :: any
		end)
		return success, result
	end,

	UpdateAsync = function(RequestInfo: Request): (boolean, any)
		local datastore: DataStore | OrderedDataStore = RequestInfo.DataStore
		local key: string = RequestInfo.Key
		local transform: (data: any) -> any = RequestInfo.ExtraData.TransformFunction
		local success: boolean, result: any = pcall(datastore.UpdateAsync, datastore, key, transform)
		return success, result
	end,

	RemoveAsync = function(RequestInfo: Request): (boolean, any)
		local datastore: DataStore | OrderedDataStore = RequestInfo.DataStore
		local key: string = RequestInfo.Key
		local success: boolean, result: any = pcall(datastore.RemoveAsync, datastore, key)
		return success, result
	end,

	GetVersionAsync = function(RequestInfo: Request): (boolean, any)
		local datastore: DataStore = RequestInfo.DataStore :: DataStore
		local key: string = RequestInfo.Key
		local version: string = RequestInfo.ExtraData.Version
		local success: boolean, result: any = pcall(datastore.GetVersionAsync, datastore, key, version)
		return success, result
	end,

	GetVersionAtTimeAsync = function(RequestInfo: Request): (boolean, any)
		local datastore: DataStore = RequestInfo.DataStore :: DataStore
		local key: string = RequestInfo.Key
		local timestamp: number = RequestInfo.ExtraData.Timestamp
		local success: boolean, result: any = pcall(datastore.GetVersionAtTimeAsync, datastore, key, timestamp)
		return success, result
	end,

	ListVersionsAsync = function(RequestInfo: Request): (boolean, DataStoreVersionPages)
		local datastore: DataStore = RequestInfo.DataStore :: DataStore
		local key: string = RequestInfo.Key
		local sortDir: Enum.SortDirection? = RequestInfo.ExtraData.SortDirection
		local pageSize: number? = RequestInfo.ExtraData.PageSize
		local minDate: number? = RequestInfo.ExtraData.MinDate
		local maxDate: number? = RequestInfo.ExtraData.MaxDate
		local success: boolean, result: DataStoreVersionPages =
			pcall(datastore.ListVersionsAsync, datastore, key, sortDir, pageSize, minDate, maxDate)
		return success, result
	end,

	ListKeysAsync = function(RequestInfo: Request): (boolean, DataStoreKeyPages)
		local datastore: DataStore = RequestInfo.DataStore :: DataStore
		local prefix: string? = RequestInfo.ExtraData.Prefix
		local pageSize: number? = RequestInfo.ExtraData.PageSize
		local cursor: string? = RequestInfo.ExtraData.Cursor
		local excludeDeleted: boolean? = RequestInfo.ExtraData.ExcludeDeleted
		local success: boolean, pages: DataStoreKeyPages =
			pcall(datastore.ListKeysAsync, datastore, prefix, pageSize, cursor, excludeDeleted)
		return success, pages
	end,

	RemoveVersionAsync = function(RequestInfo: Request): (boolean, any)
		local datastore: DataStore = RequestInfo.DataStore :: DataStore
		local key: string = RequestInfo.Key
		local version: string = RequestInfo.ExtraData.Version
		local success: boolean, result: any = pcall(datastore.RemoveVersionAsync, datastore, key, version)
		return success, result
	end,
	ListDataStoresAsync = function(RequestInfo: Request): (boolean, DataStoreListingPages)
		local extraData: { [string]: any } = RequestInfo.ExtraData
		local prefix: string? = extraData.Prefix
		local pageSize: number? = extraData.PageSize
		local cursor: string? = extraData.Cursor

		local success: boolean, result: DataStoreListingPages =
			pcall(DataStoreService.ListDataStoresAsync, DataStoreService, prefix, pageSize, cursor)

		return success, result
	end,
}

--== Helper functions ==--

local function Log<T...>(level: number, ...: T...): ()
	if level > LOG_LEVEL then
		return
	end

	local fn: <T...>(T...) -> () = level == 1 and warn or print
	fn(`[{script.Name}] `, ...)
end

local function SafeThreadResume(thread: thread, ...)
	if thread and coroutine.status(thread) == "suspended" then
		task.spawn(thread, ...)
		Log(3, `successfully resumed thread`)
	else
		Log(2, `failed to resume thread: the thread status is not suspended`)
	end
end

-- Checks whether the key is valid for write/read/readwrite operation
local function IsKeyValid(
	Datastore: DataStore | OrderedDataStore | Pages,
	Key: string?,
	mode: ("Read" | "Write")?
): boolean
	-- if key is not provided = return true as the request does not require any key handling
	if Key == nil then
		return true
	end

	-- fetch info
	local info = Processor.KeyRegistry[Datastore :: DataStore | OrderedDataStore][Key]
	if not info then
		return true
	end

	-- return result
	if mode == "Read" then
		-- Valid if nobody is writing
		return (not info.Writing) and (info.PendingWrites == 0)
	else
		-- Valid if nobody is writing AND nobody is reading
		return (not info.Writing) and (info.ActiveReaders == 0)
	end
end

-- if a key is not valid for the request, yields until the lock is available
local function AcquireKeyLock(Datastore: DataStore | OrderedDataStore, Key: string, mode: "Read" | "Write"): ()
	Log(3, `Acquiring {mode} mode for key {Key}`)
	-- fetch registry
	local info: { ActiveReaders: number, Writing: boolean, RefCount: number, PendingWrites: number } =
		Processor.KeyRegistry[Datastore][Key]
	if not info then
		info = { ActiveReaders = 0, Writing = false, RefCount = 0, PendingWrites = 0 }
		Processor.KeyRegistry[Datastore][Key] = info
	end

	local currentCoroutine = coroutine.running()

	if mode == "Write" then
		info.PendingWrites += 1
	end

	while not IsKeyValid(Datastore, Key, mode) do
		-- if the key is not valid = enqueue the coroutine and yield until the key is available
		Log(3, `Key {Key} is not valid for {mode} yet, yielding until it will`)
		Processor.KeyWaiters[Datastore][Key] = Processor.KeyWaiters[Datastore][Key] or { Read = {}, Write = {} }
		local Waiters: { [string]: { thread? } } = Processor.KeyWaiters[Datastore][Key]
		table.insert(Waiters[mode], currentCoroutine)
		coroutine.yield()
	end
	Log(3, `Successfully acquired {mode} mode for key {Key}`)
	info.RefCount += 1
	if mode == "Write" then
		info.PendingWrites -= 1
		info.Writing = true
	else
		info.ActiveReaders += 1
	end
end

-- Helper function to clean up empty key's waiters data
local function CleanupKeyWaiters(DataStore: DataStore | OrderedDataStore, Key: string): ()
	-- fetch waiters
	local Waiters = Processor.KeyWaiters[DataStore][Key]
	if Waiters then
		-- iterate through every mode table, if at least one table has a waiting coroutine = do not cleanup
		-- otherwise we just clean up the data
		local AllEmpty = true
		for _, v in Waiters :: { [string]: { thread? } } do
			if #v ~= 0 then
				AllEmpty = false
				break
			end
		end
		if AllEmpty then
			Processor.KeyWaiters[DataStore][Key] = nil
		end
	end
end

-- Releases the key lock to free up access for another same key-mode requests
local function ReleaseKeyLock(Datastore: DataStore | OrderedDataStore, Key: string, mode: "Read" | "Write"): ()
	local info = Processor.KeyRegistry[Datastore][Key]
	-- if the info somehow does not exist = return, since there is nothing to release
	if not info then
		Log(1, `Key({Key}) info does not exist`)
		return
	end
	Log(3, `Releasing key lock for key {Key}`)
	info.RefCount -= 1

	if mode == "Write" then
		info.Writing = false
	else
		info.ActiveReaders -= 1
	end

	local keyWaiters = Processor.KeyWaiters[Datastore][Key]
	if not keyWaiters then
		return
	end
	if info.ActiveReaders == 0 and not info.Writing and #keyWaiters.Write > 0 then
		SafeThreadResume(table.remove(keyWaiters.Write, 1) :: any)
		return
	end

	while not info.Writing and info.PendingWrites == 0 and #keyWaiters.Read > 0 do
		SafeThreadResume(table.remove(keyWaiters.Read, 1) :: any)
	end
	CleanupKeyWaiters(Datastore, Key)

	if (info.RefCount :: number) <= 0 then
		Processor.KeyRegistry[Datastore][Key] = nil
	end
end

local function Enqueue(Queue: Queue, Request: Request): ()
	-- Create a new node with the request
	local NewNode: QueueNode = {
		Request = Request,
		Next = nil :: QueueNode?,
	}

	if Queue.Tail then
		-- If the queue is not empty, attach the new node to the current tail
		Queue.Tail.Next = NewNode
	else
		-- If the queue is empty, this node is both the head and the tail
		Queue.Head = NewNode
	end

	-- Update the tail pointer
	Queue.Tail = NewNode :: { Next: QueueNode, Request: Request }

	-- Increment the count
	Queue.Count = Queue.Count :: number + 1
end

local function Dequeue(Queue: Queue): Request?
	if not Queue.Head then
		-- Queue is empty
		return nil
	end

	-- 1. Get the Request from the Head
	local Request = Queue.Head.Request

	-- 2. Move the Head pointer to the next node
	local NewHead = Queue.Head.Next

	-- 3. Clear the reference to aid garbage collection
	Queue.Head.Request = nil :: any
	Queue.Head.Next = nil :: any

	Queue.Head = NewHead :: any

	if not NewHead then
		-- If the new head is nil, the queue is now empty. Reset the Tail too.
		Queue.Tail = nil :: any
	end

	-- 4. Decrement the count
	Queue.Count = Queue.Count :: number - 1

	return Request
end

local function GenerateRequestId(): number
	EliteDataStoreService.TotalRequests += 1
	return EliteDataStoreService.TotalRequests
end

local function ProcessRequest(Request: Request): ()
	task.spawn(function()
		Log(2, `Processing current request(id: {Request.Id})`)
		if Request.Key then
			Log(3, `Key exists, acquiring key lock`)
			AcquireKeyLock(Request.DataStore :: any, Request.Key, Request.KeyAccessMode)
		end
		-- re-check the budget to ensure reliability
		if DataStoreService:GetRequestBudgetForRequestType(Request.RequestType) < 1 then
			Log(
				2,
				`After key acquire the budget was exhausted, dropping the request to get it processed in the next iteration cycle(id: {Request.Id})`
			)
			-- while we waited for the key, the budget was exhausted, put the request to dropped requests to then process it
			if Request.Key then
				ReleaseKeyLock(Request.DataStore :: any, Request.Key, Request.KeyAccessMode)
			end

			Enqueue(Processor.DroppedRequests :: any, Request)

			return
		end
		Log(2, `All validations passed, processing the request(id: {Request.Id})`)
		local success, result = Requests[Request.RequestName](Request)
		if Request.Key then
			ReleaseKeyLock(Request.DataStore :: any, Request.Key, Request.KeyAccessMode)
		end
		Log(2, `Request processed, results: `, success, result)
		if Request.Cor and coroutine.status(Request.Cor) == "suspended" then
			SafeThreadResume(Request.Cor :: thread, success, result)
		end
	end)
end

local function IsRequestValid(request: Request): boolean
	Log(2, `Checking if request is valid (id: {request.Id})`)
	local RequestType = request.RequestType

	if DataStoreService:GetRequestBudgetForRequestType(RequestType) <= 0 then
		Log(2, `Not enough budget, request is not valid`)
		return false
	end

	local Key = request.Key
	local mode = request.KeyAccessMode
	if Key and not IsKeyValid(request.DataStore :: any, Key, mode :: any) then
		Log(2, `Key is locked, request is not valid`)
		return false
	end

	Log(2, `Request is valid`)

	return true
end

local function IterateThrough(Queue: Queue, QueueName: string): ()
	if Queue.Count < 1 or Processor[QueueName .. "Processing"] then
		Log(2, `{QueueName} is empty or it is already processing, cancelling operation`)
		return
	end
	Processor[QueueName .. "Processing"] = true

	local InitialCount = Queue.Count
	Log(2, `{QueueName} iteration started, queue size: {InitialCount}`)

	for i = 1, InitialCount do
		if not Queue.Head then
			-- this is unlikely to happen
			Log(
				1,
				`Unexpected situation occurred, queue count is greater than 0 however the head does not exist, cancelling iteration.`
			)
			break
		end

		local request = Queue.Head.Request :: Request

		if IsRequestValid(request) then
			-- we can process the request = dequeue and start processing
			Dequeue(Queue)
			ProcessRequest(request)
		else
			-- we cant process the request = push it to the bottom of the queue
			Dequeue(Queue)
			Enqueue(Queue :: any, request)
		end
	end

	-- iteration finished
	Log(2, `{QueueName} iteration finished, queue size: {Queue.Count}`)
	Processor[QueueName .. "Processing"] = false
end

local function AreQueuesEmpty(): boolean
	return Processor.Queue.Count == 0 and Processor.PriorityQueue.Count == 0 and Processor.DroppedRequests.Count == 0
end

local function PerformDatastoreRequest(
	RequestName: string,
	DataStore: (DataStore | OrderedDataStore | Pages)?,
	Key: string?,
	KeyAccessMode: ("Read" | "Write")?,
	RequestType: Enum.DataStoreRequestType,
	ExtraData: { [string]: any }?,
	Prioritize: boolean?
): (boolean, any)
	local Request = {
		Id = GenerateRequestId(),
		Key = Key,
		KeyAccessMode = KeyAccessMode,
		DataStore = DataStore,
		ExtraData = ExtraData,
		RequestType = RequestType,
		RequestName = RequestName,
		Cor = coroutine.running(),
	}
	Log(2, `Performing data store request {RequestName}, request table: `, Request)

	local function addToQueue(): (boolean, any)
		local queue: Queue = Prioritize and Processor.PriorityQueue or Processor.Queue

		Enqueue(queue, Request :: any)
		Processor.FinishedAll = false

		return coroutine.yield()
	end

	-- First check if there is not any requests in queues
	if AreQueuesEmpty() and IsKeyValid(DataStore :: DataStore, Key :: string, KeyAccessMode) then
		Log(2, `Queues are empty and the request is valid, trying to process request`)
		if Key then
			-- if key exists, its a read/write operation so we ensure no other simultaneous read/writes are happening
			AcquireKeyLock(DataStore :: DataStore, Key, KeyAccessMode :: "Read" | "Write")
		end
		-- check if the budget wasnt exhausted
		if DataStoreService:GetRequestBudgetForRequestType(RequestType) < 1 then
			-- budget is exhausted = enqueue the request
			Log(2, `After key acquire process the budget was exhausted, enqueuing the request`)
			return addToQueue()
		end
		-- otherwise process the request instantly
		Log(2, `All validations completed, processing the request`)
		local success, result = Requests[Request.RequestName](Request :: any)
		if Key then
			-- if key exists = release the lock so that other read/write requests continue processing
			ReleaseKeyLock(DataStore :: DataStore, Key, KeyAccessMode :: "Read" | "Write")
		end
		Log(2, `Request processing completed, results: `, success, result)
		return success, result
	else
		-- queues are not empty or the key did not pass the validation
		Log(2, `Queues are not empty or the key did not pass the validation, enqueuing the request`)
		return addToQueue()
	end
end

--== Main loop ==--

local elapsed: number = 0
RunService.Heartbeat:Connect(function(delta: number): ()
	if Processor.FinishedAll then
		return
	end

	elapsed += delta

	if elapsed >= Processor.IterationCycle then
		elapsed = 0
		Log(3, `Iteration cycle began`)
		IterateThrough(Processor.DroppedRequests :: Queue, "DroppedRequests")
		IterateThrough(Processor.PriorityQueue :: Queue, "PriorityQueue")
		IterateThrough(Processor.Queue :: Queue, "Queue")
		Log(3, `Iteration cycle ended`)
		if AreQueuesEmpty() then
			Processor.FinishedAll = true
		end
	end
end)

--== Module API ==--

local EliteDataStore = {}
EliteDataStore.__index = EliteDataStore

local EliteDataStorePages = {}
EliteDataStorePages.__index = EliteDataStorePages

local function CreateDataStore(
	Name: string,
	Scope: string?,
	Opts: DataStoreOptions?,
	IsOrderedDS: boolean?
): EliteDataStore | EliteOrderedDataStore
	local id = `{IsOrderedDS and "O" or "N"}_{Name}_{Scope or ""}`
	if DatastoresCache[id] then
		return DatastoresCache[id]
	end
	local self = setmetatable({}, EliteDataStore)
	self.Name = Name
	self.Scope = Scope
	self.DS = IsOrderedDS and DataStoreService:GetOrderedDataStore(Name, Scope)
		or DataStoreService:GetDataStore(Name, Scope, Opts)
	self.Ordered = IsOrderedDS == true
	Processor.KeyRegistry[self.DS] = {}
	Processor.KeyWaiters[self.DS] = {}
	DatastoresCache[id] = self :: any
	return self :: any
end

local function CreateEliteDataStorePages(PagesObj: Pages): EliteDataStorePages
	local self = setmetatable({}, EliteDataStorePages)
	self.Pages = PagesObj
	return self :: any
end

function EliteDataStorePages:GetCurrentPage(): { any }
	return self.Pages:GetCurrentPage()
end

function EliteDataStorePages:AdvanceToNextPage(Prioritize: boolean?): (boolean, string?)
	local success, err = PerformDatastoreRequest(
		"AdvanceToNextPageAsync",
		self.Pages,
		nil,
		nil,
		Enum.DataStoreRequestType.GetSortedAsync,
		nil,
		Prioritize
	)

	return success, err
end

function EliteDataStorePages:IsFinished(): boolean
	return self.Pages.IsFinished == true
end

function EliteDataStoreService:SetIterationCycle(n: number): ()
	Processor.IterationCycle = n
end

function EliteDataStoreService:GetDataStore(DataStoreName: string, Scope: string?, Options: DataStoreOptions?)
	return CreateDataStore(DataStoreName, Scope, Options, false)
end

function EliteDataStoreService:GetGlobalDataStore(): EliteDataStore
	if DatastoresCache.___GLOBAL then
		return DatastoresCache.___GLOBAL :: any
	end
	local global = setmetatable({}, EliteDataStore)
	global.DS = DataStoreService:GetGlobalDataStore()
	self.Ordered = false
	Processor.KeyRegistry[global.DS] = {}
	Processor.KeyWaiters[global.DS] = {}
	DatastoresCache.___GLOBAL = self
	return global :: any
end

function EliteDataStoreService:GetOrderedDataStore(DataStoreName: string, Scope: string?): EliteOrderedDataStore
	return CreateDataStore(DataStoreName, Scope, nil, true) :: EliteOrderedDataStore
end

function EliteDataStoreService:ListDataStores(
	Prefix: string?,
	PageSize: number?,
	Cursor: string?,
	Prioritize: boolean?
): (boolean, EliteDataStorePages<DataStoreListingPagesEntry>)
	local success, result = PerformDatastoreRequest(
		"ListDataStoresAsync",
		nil,
		nil,
		nil,
		Enum.DataStoreRequestType.ListAsync,
		{ Prefix = Prefix, PageSize = PageSize, Cursor = Cursor },
		Prioritize
	)

	local pages: any = success and CreateEliteDataStorePages(result) or nil
	return success, pages or result
end

function EliteDataStoreService:WaitForAllRequests(): ()
	repeat
		task.wait()
	until Processor.FinishedAll
end

function EliteDataStoreService:GetRequestBudgetForRequestType(RequestType: Enum.DataStoreRequestType): number
	return DataStoreService:GetRequestBudgetForRequestType(RequestType)
end

function EliteDataStoreService:GetQueueSize(): number
	return Processor.Queue.Count
end

function EliteDataStoreService:GetPriorityQueueSize(): number
	return Processor.PriorityQueue.Count
end

function EliteDataStoreService:GuardCall(
	Method: (...any) -> (boolean, any),
	MaxRetries: number?,
	RetriesIntermission: number?,
	ExponentialBackoff: boolean?,
	...: any
): (boolean, any)
	if ExponentialBackoff == nil then
		ExponentialBackoff = DEFAULT_EXPONENTIAL_BACKOFF
	end
	local success, result
	local attempts = 0
	repeat
		attempts += 1
		success, result = Method(...)
		if not success then
			Log(1, `Failed to process current request, error: {result}`)
			task.wait((RetriesIntermission or DEFAULT_RETRIES_INTERMISSION) * (ExponentialBackoff and attempts or 1))
		end
	until success or attempts >= (MaxRetries or DEFAULT_MAX_RETRIES)

	return success, result
end

function EliteDataStoreService:CheckDataStoreAccess(): "NoAccess" | "NoInternet" | "Access"
	if not RunService:IsStudio() then
		return "Access"
	end
	local new_state = "NoAccess"

	local status, message = pcall(function()
		-- This will error if current instance has no Studio API access:
		DataStoreService:GetDataStore("____TEST"):GetAsync("____TEST")
		return ""
	end)

	local no_internet_access = status == false and string.find(message, "ConnectFail", 1, true) ~= nil

	if no_internet_access == true then
		Log(1, `[{script.Name}]: No internet access - check your network connection`)
	end

	if
		status == false
		and (
			string.find(message, "403", 1, true) ~= nil -- Cannot write to DataStore from studio if API access is not enabled
			or string.find(message, "must publish", 1, true) ~= nil -- Game must be published to access live keys
			or no_internet_access == true
		)
	then -- No internet access
		new_state = if no_internet_access == true then "NoInternet" else "NoAccess"
		Log(2, `[{script.Name}]: Roblox API services unavailable - data will not be saved`)
	else
		new_state = "Access"
		Log(2, `[{script.Name}]: Roblox API services available - data will be saved`)
	end

	return new_state :: "Access" | "NoAccess" | "NoInternet"
end

function EliteDataStoreService:ReplaceDataStoreServiceWithCustomHandler(Handler: typeof(DataStoreService)): ()
	DataStoreService = Handler
end

function EliteDataStore:CanRead(Key: string): boolean
	return IsKeyValid(self.DS, Key, "Read")
end

function EliteDataStore:CanWrite(Key: string): boolean
	return IsKeyValid(self.DS, Key, "Write")
end

function EliteDataStore:Get(Key: string, Options: DataStoreGetOptions?, Prioritize: boolean?): (boolean, any)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif Options ~= nil and (typeof(Options) ~= "Instance" or not (Options :: any):IsA("DataStoreGetOptions")) then
		error(`Invalid argument #2, nil or DataStoreGetOptions expected, got {typeof(Options)}`)
	end

	Key = tostring(Key)

	return PerformDatastoreRequest(
		"GetAsync",
		self.DS,
		Key,
		"Read",
		Enum.DataStoreRequestType.GetAsync,
		{ Options = Options },
		Prioritize
	)
end

function EliteDataStore:GetSorted(
	Ascending: boolean,
	PageSize: number,
	MinValue: number?,
	MaxValue: number?,
	Prioritize: boolean?
): (boolean, EliteDataStorePages<DataStorePagesEntry>)
	if not self.Ordered then
		error("Cannot use GetSorted on a non-Ordered DataStore")
	elseif typeof(Ascending) ~= "boolean" then
		error(`Invalid argument #1, boolean expected, got {typeof(Ascending)}`)
	elseif typeof(PageSize) ~= "number" then
		error(`Invalid argument #2, number expected, got {typeof(PageSize)}`)
	elseif MinValue ~= nil and typeof(MinValue) ~= "number" then
		error(`Invalid argument #3, nil or number expected, got {typeof(MinValue)}`)
	elseif MaxValue ~= nil and typeof(MaxValue) ~= "number" then
		error(`Invalid argument #4, nil or number expected, got {typeof(MaxValue)}`)
	end

	local success: boolean, result: any =
		PerformDatastoreRequest("GetSortedAsync", self.DS, nil, nil, Enum.DataStoreRequestType.GetSortedAsync, {
			Ascending = Ascending,
			PageSize = PageSize,
			MinValue = MinValue,
			MaxValue = MaxValue,
		}, Prioritize)

	local ElitePages: any = success and CreateEliteDataStorePages(result) or nil
	return success, ElitePages or result
end

function EliteDataStore:Set(
	Key: string,
	Value: any,
	UserIds: { number }?,
	Options: DataStoreSetOptions?,
	Prioritize: boolean?
): (boolean, any)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end
	if UserIds ~= nil and typeof(UserIds) ~= "table" then
		error(`Invalid argument #3, table expected, got {typeof(UserIds)}`)
	elseif Options ~= nil and (typeof(Options) ~= "Instance" or not Options:IsA("DataStoreSetOptions")) then
		error(`Invalid argument #4, nil or DataStoreSetOptions expected, got {typeof(Options)}`)
	elseif self.Ordered and typeof(Value) ~= "number" then
		error(`Cannot save non-number data to Ordered Datastores`)
	end

	Key = tostring(Key)

	local requestType = self.Ordered and Enum.DataStoreRequestType.SetIncrementSortedAsync
		or Enum.DataStoreRequestType.SetIncrementAsync
	return PerformDatastoreRequest(
		"SetAsync",
		self.DS,
		Key,
		"Write",
		requestType,
		{ Value = Value, UserIds = UserIds, Options = Options },
		Prioritize
	)
end

function EliteDataStore:Update(Key: string, TransformFunction: (Data: any) -> any, Prioritize: boolean?): (boolean, any)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif typeof(TransformFunction) ~= "function" then
		error(`Invalid argument #2, function expected, got {typeof(TransformFunction)}`)
	end
	Key = tostring(Key)

	return PerformDatastoreRequest(
		"UpdateAsync",
		self.DS,
		Key,
		"Write",
		Enum.DataStoreRequestType.UpdateAsync,
		{ TransformFunction = TransformFunction },
		Prioritize
	)
end

function EliteDataStore:Remove(Key: string, Prioritize: boolean?): (boolean, any)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	end

	Key = tostring(Key)

	local requestType = self.Ordered and Enum.DataStoreRequestType.SetIncrementSortedAsync
		or Enum.DataStoreRequestType.SetIncrementAsync
	return PerformDatastoreRequest("RemoveAsync", self.DS, Key, "Write", requestType, nil, Prioritize)
end

function EliteDataStore:Increment(
	Key: string,
	Delta: number?,
	UserIds: { number }?,
	Options: DataStoreIncrementOptions?,
	Prioritize: boolean?
): (boolean, number)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif Delta ~= nil and typeof(Delta) ~= "number" then
		error(`Invalid argument #2, number expected, got {typeof(Delta)}`)
	elseif UserIds ~= nil and typeof(UserIds) ~= "table" then
		error(`Invalid argument #3, table expected, got {typeof(UserIds)}`)
	elseif Options ~= nil and (typeof(Options) ~= "Instance" or not Options:IsA("DataStoreIncrementOptions")) then
		error(`Invalid argument #4, nil or DataStoreIncrementOptions expected, got {typeof(Options)}`)
	end

	Key = tostring(Key)

	local requestType = self.Ordered and Enum.DataStoreRequestType.SetIncrementSortedAsync
		or Enum.DataStoreRequestType.SetIncrementAsync
	return PerformDatastoreRequest(
		"IncrementAsync",
		self.DS,
		Key,
		"Write",
		requestType,
		{ Delta = Delta, UserIds = UserIds, Options = Options },
		Prioritize
	)
end

function EliteDataStore:ListKeys(
	Prefix: string?,
	PageSize: number?,
	Cursor: string?,
	ExcludeDeleted: boolean?,
	Prioritize: boolean?
): (boolean, EliteDataStorePages<DataStoreKeyPagesEntry>)
	if Prefix ~= nil and typeof(Prefix) ~= "string" then
		error(`Invalid argument #1, string expected, got {typeof(Prefix)}`)
	elseif PageSize ~= nil and typeof(PageSize) ~= "number" then
		error(`Invalid argument #2, number expected, got {typeof(PageSize)}`)
	elseif Cursor ~= nil and typeof(Cursor) ~= "string" then
		error(`Invalid argument #3, string expected, got {typeof(Cursor)}`)
	elseif ExcludeDeleted ~= nil and typeof(ExcludeDeleted) ~= "boolean" then
		error(`Invalid argument #4, boolean expected, got {typeof(ExcludeDeleted)}`)
	end

	local success, result = PerformDatastoreRequest(
		"ListKeysAsync",
		self.DS,
		nil,
		nil,
		Enum.DataStoreRequestType.ListAsync,
		{ Prefix = Prefix, PageSize = PageSize, Cursor = Cursor, ExcludeDeleted = ExcludeDeleted },
		Prioritize
	)

	local ElitePages = success and CreateEliteDataStorePages(result) or nil

	return success, (ElitePages or result) :: any
end

function EliteDataStore:ListVersions(
	Key: string,
	SortDirection: Enum.SortDirection?,
	MinDate: number?,
	MaxDate: number?,
	PageSize: number?,
	Prioritize: boolean?
): (boolean, EliteDataStorePages<DataStoreVersionPagesEntry>)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif SortDirection ~= nil and typeof(SortDirection) ~= "EnumItem" then
		error(`Invalid argument #2, Enum.SortDirection expected, got {typeof(SortDirection)}`)
	elseif MinDate ~= nil and typeof(MinDate) ~= "number" then
		error(`Invalid argument #3, number expected, got {typeof(MinDate)}`)
	elseif MaxDate ~= nil and typeof(MaxDate) ~= "number" then
		error(`Invalid argument #4, number expected, got {typeof(MaxDate)}`)
	elseif PageSize ~= nil and typeof(PageSize) ~= "number" then
		error(`Invalid argument #5, number expected, got {typeof(PageSize)}`)
	end

	Key = tostring(Key)

	local success, result = PerformDatastoreRequest(
		"ListVersionsAsync",
		self.DS,
		Key,
		"Read",
		Enum.DataStoreRequestType.ListAsync,
		{ SortDirection = SortDirection, MinDate = MinDate, MaxDate = MaxDate, PageSize = PageSize },
		Prioritize
	)
	local ElitePages = success and CreateEliteDataStorePages(result) or nil
	return success, (ElitePages or result) :: any
end

function EliteDataStore:GetVersion(Key: string, Version: any, Prioritize: boolean?): (boolean, any)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif typeof(Version) ~= "string" then
		error(`Invalid argument #2, string expected, got {typeof(Version)}`)
	end

	Key = tostring(Key)

	return PerformDatastoreRequest(
		"GetVersionAsync",
		self.DS,
		Key,
		"Read",
		Enum.DataStoreRequestType.GetVersionAsync,
		{ Version = Version },
		Prioritize
	)
end

function EliteDataStore:GetVersionAtTime(Key: string, Timestamp: number, Prioritize: boolean?): (boolean, any)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif typeof(Timestamp) ~= "number" then
		error(`Invalid argument #2, number expected, got {typeof(Timestamp)}`)
	end

	Key = tostring(Key)

	return PerformDatastoreRequest(
		"GetVersionAtTimeAsync",
		self.DS,
		Key,
		"Read",
		Enum.DataStoreRequestType.GetVersionAsync,
		{ Timestamp = Timestamp },
		Prioritize
	)
end

function EliteDataStore:RemoveVersion(Key: string, Version: string, Prioritize: boolean?): (boolean, any)
	if not tostring(Key) then
		error(`Invalid argument #1, string expected, got {typeof(Key)}`)
	elseif typeof(Version) ~= "string" then
		error(`Invalid argument #2, string expected, got {typeof(Version)}`)
	end

	Key = tostring(Key)

	return PerformDatastoreRequest(
		"RemoveVersionAsync",
		self.DS,
		Key,
		"Write",
		Enum.DataStoreRequestType.RemoveVersionAsync,
		{ Version = Version },
		Prioritize
	)
end

--== Shutdown Handling ==--
game:BindToClose(function(): ()
	task.wait(2) -- small delay for server scripts to handle shutdown
	repeat
		task.wait()
	until Processor.FinishedAll
end)

--== Type Annotations ==--

export type EliteDataStoreService = {
	-- Attributes
	TotalRequests: number,

	-- Methods
	GetDataStore: (
		self: EliteDataStoreService,
		name: string,
		scope: string?,
		options: DataStoreOptions?
	) -> EliteDataStore,
	GetOrderedDataStore: (self: EliteDataStoreService, name: string, scope: string?) -> EliteOrderedDataStore,
	GetGlobalDataStore: (self: EliteDataStoreService) -> EliteDataStore,
	GetRequestBudgetForRequestType: (self: EliteDataStoreService, RequestType: Enum.DataStoreRequestType) -> number,
	ListDataStores: (
		self: EliteDataStoreService,
		prefix: string?,
		pagesize: number?,
		cursor: string?
	) -> (boolean, EliteDataStorePages<DataStoreListingPagesEntry>),

	-- Extras
	SetIterationCycle: (self: EliteDataStoreService, seconds: number) -> (),
	WaitForAllRequests: (self: EliteDataStoreService) -> (),
	GetQueueSize: (self: EliteDataStoreService) -> (),
	GetPriorityQueueSize: (self: EliteDataStoreService) -> (),
	CheckDataStoreAccess: (self: EliteDataStoreService) -> "Access" | "NoAccess" | "NoInternet",
	ReplaceDataStoreServiceWithCustomHandler: (self: EliteDataStoreService, Handler: any) -> (),
	GuardCall: (
		self: EliteDataStoreService,
		method: (...any) -> (boolean, any),
		MaxRetries: number?,
		RetriesIntermission: number?,
		ExponentialBackoff: boolean?,
		...any
	) -> (boolean, any),
}

export type BaseEliteDataStore = {
	-- Attributes
	Name: string,
	Scope: string?,
	Ordered: boolean,

	Get: (
		self: BaseEliteDataStore,
		key: string | number,
		options: DataStoreGetOptions?,
		prioritize: boolean?
	) -> (boolean, any),
	Set: (
		self: BaseEliteDataStore,
		key: string | number,
		value: any,
		userIds: { number }?,
		options: DataStoreSetOptions?,
		prioritize: boolean?
	) -> (boolean, any),
	Increment: (
		self: BaseEliteDataStore,
		key: string | number,
		delta: number?,
		userIds: { number }?,
		options: DataStoreIncrementOptions?,
		prioritize: boolean?
	) -> (boolean, any),
	Update: (
		self: BaseEliteDataStore,
		key: string | number,
		transformFunction: (any) -> any,
		prioritize: boolean?
	) -> (boolean, any),
	Remove: (self: BaseEliteDataStore, key: string | number, prioritize: boolean?) -> (boolean, any),

	CanRead: (self: EliteDataStoreService, key: string | number) -> boolean,
	CanWrite: (self: EliteDataStoreService, key: string | number) -> boolean,
}

export type EliteDataStore = BaseEliteDataStore & {
	GetVersion: (
		self: BaseEliteDataStore,
		key: string | number,
		version: string,
		prioritize: boolean?
	) -> (boolean, any),
	GetVersionAtTime: (
		self: BaseEliteDataStore,
		key: string | number,
		timestamp: number,
		prioritize: boolean?
	) -> (boolean, any),
	ListVersions: (
		self: BaseEliteDataStore,
		key: string | number,
		sortDirection: Enum.SortDirection,
		pageSize: number,
		minDate: number?,
		maxDate: number?,
		prioritize: boolean?
	) -> (boolean, EliteDataStorePages<DataStoreVersionPagesEntry>),
	ListKeys: (
		self: BaseEliteDataStore,
		Prefix: string?,
		PageSize: number?,
		Cursor: string?,
		Prioritize: boolean?
	) -> (boolean, EliteDataStorePages<DataStoreKeyPagesEntry>),
	RemoveVersion: (
		self: BaseEliteDataStore,
		key: string | number,
		Version: string,
		Prioritize: boolean?
	) -> (boolean, any),
}

export type EliteOrderedDataStore = BaseEliteDataStore & {
	GetSorted: (
		self: BaseEliteDataStore,
		ascending: boolean,
		pageSize: number,
		minValue: number?,
		maxValue: number?,
		prioritize: boolean?
	) -> (boolean, EliteDataStorePages<DataStorePagesEntry>),
}

export type EliteDataStorePages<T = { any }> = {
	GetCurrentPage: (self: any) -> { T },
	AdvanceToNextPage: (self: any, prioritize: boolean?) -> (boolean, any),
	IsFinished: (self: any) -> boolean,
}

export type DataStorePagesEntry = { key: string, value: number }
export type DataStoreKeyPagesEntry = { KeyName: string }
export type DataStoreVersionPagesEntry = { Version: string, CreatedTime: number, IsDeleted: boolean }
export type DataStoreListingPagesEntry = { DataStoreName: string, CreatedTime: number }

export type Request = {
	RequestName: string,
	RequestType: Enum.DataStoreRequestType,
	DataStore: (DataStore | OrderedDataStore | Pages)?,
	Id: number,
	Key: string?,
	KeyAccessMode: ("Read" | "Write")?,
	ExtraData: { [string]: any }?,
	Cor: thread,
} & { [string]: any }

export type QueueNode = {
	Next: QueueNode?,
	Request: Request,
}

export type Queue = { Head: QueueNode?, Tail: QueueNode?, Count: number } & { [string]: any }

return (EliteDataStoreService :: any) :: EliteDataStoreService
