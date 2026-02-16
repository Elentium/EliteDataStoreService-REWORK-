--[[
    thread v0.0.1
    by IAMNOTULTRA3 for EliteDataStoreService
]]
--!strict
-- // CONSTANTS \\ --
local MAX_THREADS = 100

-- // STATIC \\ --
local freeThreads = {}
local freeThreadsCount = 0

-- // FUNCTIONS \\ --
local function threadCallback(thread: thread, fn: (...any) -> (), ...: any)
	fn(...)
	if freeThreadsCount < MAX_THREADS then
		freeThreadsCount += 1
		freeThreads[freeThreadsCount] = thread
	end
end
local function threadLoop(thread: thread, fn: (...any) -> (), ...: any)
	fn(...)
	if freeThreadsCount < MAX_THREADS then
		freeThreadsCount += 1
		freeThreads[freeThreadsCount] = thread
	end
	while true do
		threadCallback(coroutine.yield())
	end
end

return function<A...>(fn: (A...) -> (), ...: A...): ()
	local thread
	if freeThreadsCount > 0 then
		thread = freeThreads[freeThreadsCount]
		freeThreads[freeThreadsCount] = nil
		freeThreadsCount -= 1
	else
		thread = coroutine.create(threadLoop)
	end
	task.spawn(thread, thread, fn, ...)
end
