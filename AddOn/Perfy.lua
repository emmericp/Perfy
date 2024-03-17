Perfy_GetTime = GetTimePreciseSec
local Perfy_GetTime = Perfy_GetTime
local gc = collectgarbage

--- Fields: timestamp, event, functionName, timeOverhead, memory, memoryOverhead
---@type table<number, string|number, string|number, number, number?, number?>[]
local trace = {}

local profileMemory
local isRunning

function Perfy_Trace(timestamp, event, func)
	if not isRunning then return end
	local entry
	if profileMemory then
		local mem = gc("count") * 1024
		entry = {
			timestamp, event, func, 0, mem, mem
		}
	else
		entry = {
			timestamp, event, func, 0
		}
	end
	trace[#trace + 1] = entry
	if profileMemory then
		local mem = gc("count") * 1024
		entry[6] = mem - entry[6]
	end
	entry[4] = Perfy_GetTime() - timestamp
end

function Perfy_Stop()
	gc("restart")
	isRunning = false
	-- This makes the saved variables file a bit smaller
	-- (But it doesn't save significant memory because strings are interned/unique anyways, so logging the full string above is fine)
	local functionNames = {}
	local eventNames = {}
	local funcId, eventId = 1, 1
	for _, event in ipairs(trace) do
		local eventName, funcName = event[2], event[3]
		if not eventNames[eventName] then
			eventNames[eventName] = eventId
			eventId = eventId + 1
		end
		if not functionNames[funcName] then
			functionNames[funcName] = funcId
			funcId = funcId + 1
		end
		event[2], event[3] = eventNames[eventName], functionNames[funcName]
	end
	Perfy_Export = {
		FunctionNames = functionNames,
		EventNames = eventNames,
		Trace = trace
	}
	local firstTrace = trace[1]
	local lastTrace = trace[#trace]
	if not lastTrace then
		print("[Perfy] Collected 0 traces, check if instrumentation was successful.")
		return
	end
	print(("[Perfy] Stopped profiling after %.1f seconds."):format(lastTrace[1] - firstTrace[1]))
	if lastTrace[5] then
		print(("[Perfy] Total memory allocated in this time: %.2f MiB."):format((lastTrace[5] - firstTrace[5]) / 1024 / 1024))
	end
	print(("[Perfy] Saved %d trace entries across %d unique functions."):format(#trace, funcId - 1))
	print(("[Perfy] Saved %d trace entries."):format(#trace))
end

function Perfy_Start(timeout, enableMemoryProfile)
	gc("stop")
	-- TODO: setup error handler to avoid broken stacks on uncaught errors
	isRunning = true
	profileMemory = enableMemoryProfile ~= false
	if timeout then
		C_Timer.After(timeout, Perfy_Stop)
	end
	print("[Perfy] Started profiling.")
end
