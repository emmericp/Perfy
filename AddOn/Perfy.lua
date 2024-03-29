Perfy_GetTime = GetTimePreciseSec
local Perfy_GetTime = Perfy_GetTime
local gc = collectgarbage

--- Fields: timestamp, event, functionName, timeOverhead, memory, memoryOverhead
---@type table<number, string|number, string|number, number, number?, number?>[]
local trace = {}

local TraceFieldTimestamp, TraceFieldEvent, TraceFieldFunction, TraceFieldTimeOverhead, TraceFieldMemory, TraceFieldMemoryOverhead = 1, 2, 3, 4, 5, 6

local isRunning

--[[
A few notes on the performance of the trace functions:
These are the priorities for them:
 1. It needs to be accurate and correct, so it should call GetTimePreciseSec() as close as possible to the beginning and end of it
 2. The main bottleneck is memory, so it should allocate as little as possible
 3. It should be as fast as possible to keep overhead low (even when overhead is accounted for, we don't want to slow down anything unnecessarily)

Random notes and thoughts:
 * The entry should be allocated via a single table expression, this gives an array of exact size of n entries. Growing the array after allocation grows it exponentially.
   6 entries allocated directly is (216 byte), growing an array to 6 entries allocates 8 internally in 264 bytes. That's 22% more.
 * Strings are interned and don't use extra memory if used multiple times
 * Traces can be a few GB large before you run into problems
 * Using number literals to index the entry because it's slightly faster than referencing an upvalue

Collection of ideas to maybe try:
 * Delta-encode entries and "compress" them to reduce the number of fields. (Probably doesn't work for the overhead fields)
 * Should we pre-allocate a large array for trace entries? The exponential growth will trigger huge reallocations O(log n) times
 * If we preallocate the trace array we don't need to store the memory overhead per entry as growing the array is the only reason why it's not constant
   * Even without preallocation we should be able to omit the memory overhead because the reallocation every 2^n entries should be deterministic
]]


-- Generic trace function, timestamp taken before it is called.
local function Perfy_Trace(timestamp, event, func)
	if not isRunning then return end
	local mem = gc("count") * 1024
	local entry = {
		timestamp, event, func, 0, mem, mem
	}
	trace[#trace + 1] = entry
	mem = gc("count") * 1024
	entry[6] = mem - entry[6] -- Memory overhead
	entry[4] = Perfy_GetTime() - timestamp -- Time overhead
end
_G.Perfy_Trace = Perfy_Trace

-- Trace function when leaving functions, arguments are passed through, required to instrument tail calls.
local function Perfy_Trace_Passthrough(event, func, ...)
	-- Timestamp taken here instead of in args because it must be done after all args are evaluated.
	-- Lua evaluates args left to right and vararg tail call reports mean we can't put it as last arg.
	local timestamp = Perfy_GetTime()
	if not isRunning then return ... end
	local mem = gc("count") * 1024
	local entry = {
		timestamp, event, func, 0, mem, mem
	}
	trace[#trace + 1] = entry
	mem = gc("count") * 1024
	entry[6] = mem - entry[6] -- Memory overhead
	entry[4] = Perfy_GetTime() - timestamp -- Time overhead
	return ...
end
_G.Perfy_Trace_Passthrough = Perfy_Trace_Passthrough

-- Hook coroutines
local crWrap, crResume, crYield, crRunning = coroutine.wrap, coroutine.resume, coroutine.yield, coroutine.running

---@diagnostic disable-next-line: duplicate-set-field
function coroutine.wrap(f)
	local cr = crWrap(f)
	return function(...)
		Perfy_Trace(Perfy_GetTime(), "CoroutineResume", cr)
		return cr(...)
	end
end

---@diagnostic disable-next-line: duplicate-set-field
function coroutine.resume(coroutine, ...)
	Perfy_Trace(Perfy_GetTime(), "CoroutineResume", coroutine)
	return crResume(coroutine, ...)
end

---@diagnostic disable-next-line: duplicate-set-field
function coroutine.yield(...)
	Perfy_Trace(Perfy_GetTime(), "CoroutineYield", crRunning())
	return crYield(...)
end


-- Hook error handlers
local origErrorHandler
local function errorHandler(...)
	if isRunning then
		Perfy_Trace(Perfy_GetTime(), "UncaughtError", debugstack())
	end
	return origErrorHandler(...)
end

local function hookErrorHandler()
	local curErrorHandler = geterrorhandler()
	if curErrorHandler ~= errorHandler then
		-- We may hook it multiple times across multiple starts if someone else also changes it, but worst case we have duplicate trace entries
		origErrorHandler = curErrorHandler
		seterrorhandler(errorHandler)
	end
end

local function printStats()
	local firstTrace = trace[1]
	local lastTrace = trace[#trace]
	if not lastTrace then
		print("[Perfy] Collected 0 traces, check if instrumentation was successful.")
		return
	end
	print(("[Perfy] Collected %d trace entries in %.1f seconds"):format(#trace, lastTrace[1] - firstTrace[1]))
	print(("[Perfy] Memory allocations (incl. overhead): %.2f MiB."):format((lastTrace[5] - firstTrace[5]) / 1024 / 1024))
end

local type = type
local funcId, eventId = 1, 1
local function export()
	-- Mapping all strings to numbers makes the saved variables file a bit smaller.
	-- This doesn't save memory (actually increases memory to store the lookup tables) because strings are interned/unique anyways, so logging the full string above is fine.
	local functionNames = Perfy_Export and Perfy_Export.FunctionNames or {}
	local eventNames = Perfy_Export and Perfy_Export.EventNames or {}
	local numEntries = #trace
	local yieldInterval = 1e5 -- Large traces have ~millions of entries
	local printInterval = math.floor(numEntries / 10)
	for i, event in ipairs(trace) do
		if i % yieldInterval == 0 then
			coroutine.yield()
		end
		if #trace > 1e6 and i % printInterval == 0 then
			print(("[Perfy] Exporting... %d%%"):format(math.ceil(i / numEntries * 10) * 10))
		end
		local eventName, funcName = event[TraceFieldEvent], event[TraceFieldFunction]
		if type(funcName) == "thread" or type(funcName) == "function" then
			funcName = tostring(funcName)
		end
		if type(funcName) == "string" then -- Avoid translating functions twice if we log multiple times
			if not eventNames[eventName] then
				eventNames[eventName] = eventId
				eventId = eventId + 1
			end
			if not functionNames[funcName] then
				functionNames[funcName] = funcId
				funcId = funcId + 1
			end
			event[TraceFieldEvent], event[TraceFieldFunction] = eventNames[eventName], functionNames[funcName]
		end
	end
	coroutine.yield() -- I've observed slow writes to very large exported variables, so yield one last time.
	Perfy_Export = {
		FunctionNames = functionNames,
		EventNames = eventNames,
		Trace = trace
	}
	print(("[Perfy] Saved %d trace entries across %d unique functions."):format(#trace, funcId - 1))
	-- Delay restarting gc because the freshly restarted gc will trigger a lot when allocating for building the lookup tables above.
	-- This avoids several seconds of runtime here and reduces the risk of running into a timeout which corrupts the exported data 
	coroutine.yield()
	gc("restart")
end

function Perfy_Stop()
	if not isRunning then return end
	isRunning = false
	printStats()
	local thread = coroutine.create(export)
	local function runCoroutine()
		C_Timer.After(0, function()
			if coroutine.resume(thread) then
				runCoroutine()
			end
		end)
	end
	runCoroutine()
	-- GC is restarted after exporting above
end

function Perfy_Start(timeout)
	if #trace == 0 then
		-- Make sure we don't accidentally import old saved variables
		Perfy_Clear()
	end
	gc("stop")
	hookErrorHandler()
	isRunning = true
	if timeout then
		C_Timer.After(timeout, Perfy_Stop)
	end
	print("[Perfy] Started profiling.")
	C_Timer.NewTicker(10, function(self)
		if not isRunning then
			return self:Cancel()
		end
		printStats()
	end)
end

function Perfy_Clear()
	trace = {}
	Perfy_Export = {}
	funcId = 1
	eventId = 1
end

function Perfy_Running()
	return isRunning
end
