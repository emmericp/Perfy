local mod = {}

---@return TraceEntry[]
function mod:LoadSavedVars(fileName)
	local env = {}
	if _VERSION == "Lua 5.1" then
		local f, err = loadfile(fileName)
		if not f then error(err) end
		setfenv(f, env)
		f()
	else
		---@diagnostic disable-next-line: redundant-parameter
		local f, err = loadfile(fileName, nil, env)
		if not f then error(err) end
		f()
	end
	local eventNames, functionNames = {}, {}
	for k, v in pairs(env.Perfy_Export.EventNames) do
		if eventNames[v] then error("Duplicate event name mapping: " .. k .. " has the same mapping as " .. eventNames[v]) end
		eventNames[v] = k
	end
	for k, v in pairs(env.Perfy_Export.FunctionNames) do
		if functionNames[v] then error("Duplicate function name mapping: " .. k .. " has the same mapping as " .. functionNames[v]) end
		functionNames[v] = k
	end
	local trace = {}
	for _, v in ipairs(env.Perfy_Export.Trace) do
		---@class TraceEntry
		local entry = {
			---@type number
			timestamp = v[1],
			---@type "Enter"|"Leave"
			event = eventNames[v[2]] or error("bad event id: " .. tostring(v[2])),
			---@type string
			functionName = functionNames[v[3]] or error("bad function id: " .. tostring(v[3])),
			timeOverhead = v[4] or 0,
			memory = v[5] or 0,
			memoryOverhead = v[6] or 0
		}
		trace[#trace + 1] = entry
	end
	local delta = #trace > 0 and trace[#trace].timestamp - trace[1].timestamp or 0
	print(("Loaded file with %d trace entries covering %.2f seconds."):format(#trace, delta))
	return trace
end

local stackEntryCache, isLibCache = {}, {}
local function parseStackEntry(str)
	if not str then return end
	if stackEntryCache[str] then return stackEntryCache[str], isLibCache[str] end
	local addon, firstSubDir, secondSubDir = str:match("[^%s]+ ([^/]+)/?([^/]*)/?([^/]*)/")
	local result = not firstSubDir and addon or firstSubDir and firstSubDir:match("[lL]ibs?") and secondSubDir or addon
	stackEntryCache[str] = result
	isLibCache[str] = not not (firstSubDir and firstSubDir:match("[lL]ibs?"))
	return result
end

local function backtrace(stack, coroutine)
	if #stack == 0 then return "" end
	local bt = {}
	local addonAssociation
	for _, v in ipairs(stack) do
		bt[#bt + 1] = v.functionName
		-- First addon in a call stack gets associated with the whole trace, this makes sure we don't "blame"
		-- a random addon for a shared library that is at the start of a call trace (e.g., callback or sync handler libraries)
		if not addonAssociation then
			local addon, isLib = parseStackEntry(v.functionName)
			if not isLib then
				addonAssociation = addon
			end
		end
	end
	-- Pure library trace, e.g., self time of the lowest stack entry of addons or the library actually doing something for itself.
	-- For self-times of something like libcallback we could associate this based on a lookahead on the trace, but these seem to be small/irrelevant anyways.
	addonAssociation = addonAssociation or parseStackEntry(stack[1].functionName)
	addonAssociation = addonAssociation or "Unknown addon"
	local stackPreamble = {addonAssociation}
	if coroutine.firstResume then
		stackPreamble[#stackPreamble + 1] = coroutine.firstResume
	end
	return table.concat(stackPreamble, ";") .. (#stackPreamble > 0 and ";" or "") .. table.concat(bt, ";")
end

---@param trace TraceEntry[]
function mod:FlameGraph(trace, field, overheadField)
	field = field or "timestamp"
	overheadField = overheadField or "timeOverhead"
	local result = {}
	local eventWarningsShown = {}
	---@type table<string, {stack: TraceEntry[], firstResume: string?}>
	local coroutines = {
		main = {stack = {}}
	}
	---@type string[]
	local currentCoroutine = {"main"}
	local stack = coroutines.main.stack
	for i, v in ipairs(trace) do
		local prev = trace[i - 1]
		local delta = prev and v[field] - prev[field] - prev[overheadField]
		local activeCoroutine = coroutines[currentCoroutine[#currentCoroutine]]
		local bt = backtrace(stack, activeCoroutine)
		if v.event == "Enter" then
			if #stack > 0 and delta > 0 then
				result[bt] = (result[bt] or 0) + delta
			end
			stack[#stack + 1] = v
		elseif v.event == "Leave" then
			if #stack == 0 then
				 -- incomplete traces of coroutines can trigger this
				bt = backtrace({v, {functionName = "(missing stack information due coroutine or pcall: underflow)"}}, activeCoroutine)
				result[bt] = (result[bt] or 0) + delta
			else
				local top = stack[#stack]
				if top.functionName == v.functionName then
					if delta > 0 then
						result[bt] = (result[bt] or 0) + delta
					end
					stack[#stack] = nil
					if #stack == 0 and #currentCoroutine > 1 then
						-- We are either leaving a coroutine or the start of a coroutine was not traced
						currentCoroutine[#currentCoroutine] = nil
						stack = coroutines[currentCoroutine[#currentCoroutine]].stack
					end
				else
					print("bad stack (likely coroutines or pcall/error) at " .. i .. ": leaving " .. v.functionName .. " after entering " .. top.functionName .. " backtrace: " .. bt .. " results for this stack will be off")
					while top and top.functionName ~= v.functionName do
						stack[#stack] = nil
						top = stack[#stack]
					end
					bt = backtrace({v, {functionName = "(missing stack information due coroutine or pcall: stack mismatch)"}}, activeCoroutine)
					if delta > 0 then
						result[bt] = (result[bt] or 0) + delta
					end
					stack[#stack] = nil
				end
			end
		elseif v.event == "CoroutineResume" then
			if delta > 0 then
				result[bt] = (result[bt] or 0) + delta
			end
			coroutines[v.functionName] = coroutines[v.functionName] or {stack = {}}
			if #stack > 0 then
				coroutines[v.functionName].firstResume = coroutines[v.functionName].firstResume or stack[#stack].functionName
			end
			currentCoroutine[#currentCoroutine + 1] = v.functionName
			stack = coroutines[v.functionName].stack
		elseif v.event == "CoroutineYield" then
			if delta > 0 then
				result[bt] = (result[bt] or 0) + delta
			end
			if #currentCoroutine <= 1 then -- yielding from main
				print("coroutine stack underflow at " .. i .. " in " .. (#stack > 0 and stack[#stack].functionName or "(unknown function)") .. " likely missing the start of a coroutine in a trace")
			else
				currentCoroutine[#currentCoroutine] = nil
				stack = coroutines[currentCoroutine[#currentCoroutine]].stack
			end
		elseif v.event == "UncaughtError" then -- FIXME: this has 0% test coverage
			if #stack > 0 and delta > 0 then
				result[bt] = (result[bt] or 0) + delta
			end
			for _, coroutine in ipairs(currentCoroutine) do
				coroutines[coroutine].stack = {}
			end
			currentCoroutine = {"main"}
		else
			if not eventWarningsShown[v.event] then
				print(("unknown event at entry %d: %s"):format(i, v.event))
			end
			eventWarningsShown[v.event] = true
		end
	end
	local multiplier = field == "timestamp" and 1e6 or 1
	for k, v in pairs(result) do
		result[k] = math.floor(v * multiplier + 0.5)
	end
	return result
end

return mod
