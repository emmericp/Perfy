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
		eventNames[v] = k
	end
	for k, v in pairs(env.Perfy_Export.FunctionNames) do
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

local function backtrace(stack)
	local bt = {}
	for _, v in ipairs(stack) do
		bt[#bt + 1] = v.functionName
	end
	return table.concat(bt, ";")
end

function mod:FlameGraph(trace, field, overheadField)
	field = field or "timestamp"
	overheadField = overheadField or "timeOverhead"
	---@type TraceEntry[]
	local stack = {}
	local result = {}
	for i, v in ipairs(trace) do
		local prev = trace[i - 1]
		local delta = prev and v[field] - prev[field] - prev[overheadField]
		local bt = backtrace(stack)
		if v.event == "Enter" then
			if #stack > 0 then
				result[bt] = (result[bt] or 0) + delta
			end
			stack[#stack + 1] = v
		elseif v.event == "Leave" then
			if #stack < 1 then
				 -- TODO: coroutines can trigger this, just pretend the corresponding leave event didn't exist
				print("stack underflow at " .. i)
			else
				local top = stack[#stack]
				if top.functionName == v.functionName then
					result[bt] = (result[bt] or 0) + delta
					stack[#stack] = nil
				else
					-- TODO: i'm not sure about correctness here, especially wrt coroutines
					-- this is just to make it not fail completely if it encounteres a coroutine or pcall
					print("bad stack (likely coroutines or pcall/error) at " .. i .. ": leaving " .. v.functionName .. " after entering " .. top.functionName .. " backtrace: " .. bt)
					print("results for this stack will be off")
					while top and top.functionName ~= v.functionName do
						stack[#stack] = nil
						top = stack[#stack]
					end
					if top then
						bt = backtrace(stack)
						result[bt] = (result[bt] or 0) + delta
						stack[#stack] = nil
					end
				end
			end
		else
			error("unknown event: " .. tostring(v.event))
		end
	end
	local multiplier = field == "timestamp" and 1e6 or 1
	for k, v in pairs(result) do
		result[k] = math.floor(v * multiplier + 0.5)
	end
	return result
end

return mod
