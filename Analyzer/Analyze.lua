local parser = require "LuaParser"

local mod = {}

---@return TraceEntry[]
function mod:LoadSavedVars(fileName)
	local file, err = io.open(fileName, "rb")
	if not file then error(err) end
	local fileConents = file:read("*a")
	local env = parser:ParseLua(fileConents)
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
			---@type "Enter"|"Leave"|"CoroutineResume"|"CoroutineYield"|"OnEvent"|"LoadAddOn"|"LoadAddOnFinished"|"UncaughtError"|"PerfyStart"|"PerfyStop"
			event = eventNames[v[2]] or error("bad event id: " .. tostring(v[2])),
			---@type string
			functionName = functionNames[v[3]] or error("bad function id: " .. tostring(v[3])),
			timeOverhead = v[4] or 0,
			memory = v[5] or 0,
			memoryOverhead = v[6] or 0,
			extraArg = v[7]
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
	-- Format is "functionName fileName:line:col"
	-- Function name can contain spaces iff in parentheses like "(main chunk)"
	local fileName
	if str:sub(1, 1) == "(" then
		fileName = str:match("[^)]+%) (.*)")
	else
		fileName = str:match("[^%s]+ (.*)")
	end
	if not fileName then return end
	local result, isLib
	if fileName:match("^file://") then
		result = "(unknown addon)"
		isLib = false
	else
		local addon, firstSubDir, secondSubDir = fileName:match("([^/]+)/?([^/]*)/?([^/]*)/")
		result = not firstSubDir and addon or firstSubDir and firstSubDir:match("[lL]ibs?") and secondSubDir or addon
		isLib = not not (firstSubDir and firstSubDir:match("[lL]ibs?"))
	end
	stackEntryCache[str] = result
	isLibCache[str] = isLib
	return result
end

local function backtrace(stack, coroutine, overrideAddOnAssociation)
	if #stack == 0 then return "" end
	local bt = {}
	local addonAssociation = overrideAddOnAssociation
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
	if coroutine and coroutine.firstResume then
		stackPreamble[#stackPreamble + 1] = coroutine.firstResume
	end
	return table.concat(stackPreamble, ";") .. (#stackPreamble > 0 and ";" or "") .. table.concat(bt, ";")
end

---@param trace TraceEntry[]
---@param firstFrame? TrackedFrame
---@param lastFrame? TrackedFrame
---@param frameList? TrackedFrame[]
function mod:FlameGraph(trace, field, overheadField, firstFrame, lastFrame, frameList)
	local firstTrackedOffset = firstFrame and firstFrame.first or 1
	local lastTrackedOffset = lastFrame and lastFrame.last or #trace
	if frameList then
		table.sort(frameList, function(e1, e2) return e1.id < e2.id end)
		for i = #frameList, 2, -1 do
			if frameList[i].id == frameList[i - 1].id then
				table.remove(frameList, i)
			end
		end
		lastTrackedOffset = frameList[#frameList].last
	end
	local currentTrackedFrame = nil
	local nextTrackedFrame = frameList and frameList[1]
	local nextTrackedFrameIndex = 1
	local result = {all = {}}
	local warningsShown = {}
	---@type table<string, {stack: TraceEntry[], firstResume: string?}>
	local coroutines = {
		main = {stack = {}}
	}
	---@type string[]
	local currentCoroutine = {"main"}
	local stack = coroutines.main.stack
	local prev
	local lastAddonLoaded
	local loadingAddOns = false
	-- We still need to start at the beginning even if firstTrackedOffset is set because we need to reconstruct stacks of coroutines
	for i = 1, math.min(lastTrackedOffset, #trace) do
		local v = trace[i]
		local delta = prev and v[field] - prev[field] - prev[overheadField] or 0
		local activeCoroutine = coroutines[currentCoroutine[#currentCoroutine]]
		local bt = backtrace(stack, activeCoroutine)
		if frameList then
			if nextTrackedFrame and i >= nextTrackedFrame.first then
				currentTrackedFrame = nextTrackedFrame
				nextTrackedFrameIndex = nextTrackedFrameIndex + 1
				nextTrackedFrame = frameList[nextTrackedFrameIndex]
				result[currentTrackedFrame] = {}
			end
			if currentTrackedFrame and i > currentTrackedFrame.last then
				currentTrackedFrame = nil
			end
		end
		-- FIXME: this all-in-one stack reconstruction is getting pretty messy, this should be split and cleaned up
		if v.event == "Enter" then
			if #stack > 0 then
				if delta > 0 then
					if currentTrackedFrame then
						result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
					end
					if i >= firstTrackedOffset then
						result.all[bt] = (result.all[bt] or 0) + delta
					end
				end
			elseif loadingAddOns and v.functionName:find("(main chunk)", nil, true) == 1 then
				-- Usually the time passed before an Enter from an empty stack is not accounted to anything because the time was likely spent in something that we can't account for.
				-- However, if this is the execution of main chunk and the last event is either leaving a main chunk or an ADDON_LOADED event then this was the time it took to load the file.
				-- First event we see is Perfy itself which enables this and we stop once PLAYER_LOGIN fires.
				local prevEvent = lastAddonLoaded and lastAddonLoaded.timestamp > (prev and prev.timestamp or 0) and lastAddonLoaded or prev
				if prevEvent and (prevEvent.event == "OnEvent" or prevEvent.event == "LoadAddOn" or prevEvent.event == "Leave" and prevEvent.functionName:find("(main chunk)", nil, true) == 1) then
					local delta = v[field] - prevEvent[field] - prevEvent[overheadField]
					if delta > 0 then
						local fakeStack = {}
						fakeStack[#fakeStack + 1] = {
							functionName = "(loading/compiling files, unreliable if you have uninstrumented addons)"
						}
						local fileName = v.functionName:match("%) (.*)")
						local path = ""
						for part in fileName:match("/(.*)"):gmatch("([^/]*)") do
							path = path .. "/" .. part
							fakeStack[#fakeStack + 1] = {
								functionName = path:sub(2)
							}
						end
						local bt = backtrace(fakeStack, nil, parseStackEntry(v.functionName))
						if currentTrackedFrame then
							result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
						end
						if i >= firstTrackedOffset then
							result.all[bt] = (result.all[bt] or 0) + delta
						end
					end
				end
			end
			stack[#stack + 1] = v
		elseif v.event == "Leave" then
			if #stack == 0 then
				-- incomplete traces of coroutines can trigger this
				bt = backtrace({v, {functionName = "(missing stack information due coroutine or pcall: underflow)"}}, activeCoroutine)
				if currentTrackedFrame then
					result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
				end
				if i >= firstTrackedOffset then
					result.all[bt] = (result.all[bt] or 0) + delta
				end
				v.stackEmpty = true
			else
				local top = stack[#stack]
				if top.functionName == v.functionName then
					if delta > 0 then
						if currentTrackedFrame then
							result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
						end
						if i >= firstTrackedOffset then
							result.all[bt] = (result.all[bt] or 0) + delta
						end
					end
					stack[#stack] = nil
					if #stack == 0 and #currentCoroutine > 1 then
						-- We are either leaving a coroutine or the start of a coroutine was not traced
						currentCoroutine[#currentCoroutine] = nil
						stack = coroutines[currentCoroutine[#currentCoroutine]].stack
					elseif #stack == 0 then
						v.stackEmpty = true
					end
				else
					local warningId = "bad stack " .. v.functionName .. " " .. top.functionName
					if not warningsShown[warningId] then
						warningsShown[warningId] = true
						print("bad stack (likely coroutines or pcall/error) at " .. i .. ": leaving " .. v.functionName .. " after entering " .. top.functionName .. " backtrace: " .. bt .. " results for this stack will be off")
					end
					while top and top.functionName ~= v.functionName do
						stack[#stack] = nil
						top = stack[#stack]
					end
					bt = backtrace({v, {functionName = "(missing stack information due coroutine or pcall: stack mismatch)"}}, activeCoroutine)
					if delta > 0 then
						if currentTrackedFrame then
							result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
						end
						if i >= firstTrackedOffset then
							result.all[bt] = (result.all[bt] or 0) + delta
						end
					end
					stack[#stack] = nil
					if #stack == 0 then
						v.stackEmpty = true
					end
				end
			end
		elseif v.event == "CoroutineResume" then
			if #stack > 0 then
				if delta > 0 then
					if currentTrackedFrame then
						result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
					end
					if i >= firstTrackedOffset then
						result.all[bt] = (result.all[bt] or 0) + delta
					end
				end
				coroutines[v.functionName] = coroutines[v.functionName] or {stack = {}}
				if #stack > 0 then
					coroutines[v.functionName].firstResume = coroutines[v.functionName].firstResume or stack[#stack].functionName
				end
				currentCoroutine[#currentCoroutine + 1] = v.functionName
				stack = coroutines[v.functionName].stack
			else
				local warning = "Resuming coroutine from unknown location, likely uninstrumented code, ignoring. Coroutine stacks will be off if this coroutine calls instrumented code."
				if not warningsShown[warning] then
					warningsShown[warning] = true
					print(warning)
				end
			end
		elseif v.event == "CoroutineYield" then
			if #stack > 0 then
				if delta > 0 then
					if currentTrackedFrame then
						result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
					end
					if i >= firstTrackedOffset then
						result.all[bt] = (result.all[bt] or 0) + delta
					end
				end
				if #currentCoroutine <= 1 then -- yielding from main
					local warningId = "coroutine stack underflow " .. (#stack > 0 and stack[#stack].functionName or "(unknown function)")
					if not warningsShown[warningId] then
						warningsShown[warningId] = true
						print("coroutine stack underflow at " .. i .. " in " .. (#stack > 0 and stack[#stack].functionName or "(unknown function)") .. " likely missing the start of a coroutine in a trace")
					end
					v.stackEmpty = true
				else
					currentCoroutine[#currentCoroutine] = nil
					stack = coroutines[currentCoroutine[#currentCoroutine]].stack
				end
			else
				local warning = "yielding coroutine from unknown location, likely uninstrumented code, ignoring. Coroutine stacks will be off if this coroutine calls instrumented code."
				if not warningsShown[warning] then
					warningsShown[warning] = true
					print(warning)
				end
				v.stackEmpty = true
			end
		elseif v.event == "LoadAddOn" then
			loadingAddOns = true
			lastAddonLoaded = v
			v.stackEmpty = true
		elseif v.event == "LoadAddOnFinished" then
			loadingAddOns = false
			lastAddonLoaded = nil
			v.stackEmpty = true
		elseif v.event == "UncaughtError" then -- FIXME: this has 0% test coverage
			if #stack > 0 and delta > 0 then
				if currentTrackedFrame then
					result[currentTrackedFrame][bt] = (result[currentTrackedFrame][bt] or 0) + delta
				end
				if i >= firstTrackedOffset then
					result.all[bt] = (result.all[bt] or 0) + delta
				end
			end
			for _, coroutine in ipairs(currentCoroutine) do
				coroutines[coroutine].stack = {}
			end
			currentCoroutine = {"main"}
			v.stackEmpty = true
		elseif v.event == "OnEvent" then
			-- Legacy format: event and arg in function name separated by space
			local event, eventArg = v.functionName:match("^([^%s]+) (.*)")
			if not event then
				event, eventArg = v.functionName, v.extraArg
			end
			if event == "PLAYER_LOGIN" then
				-- This only fires during a reload/login, not during normal loading screens
				loadingAddOns = false
			elseif event == "ADDON_LOADED" then
				if eventArg == "!!!Perfy" then
					loadingAddOns = true
				end
				lastAddonLoaded = v
			end
			v.stackEmpty = true
		elseif v.event == "PerfyStart" or v.event == "PerfyStop" then
			v.stackEmpty = true
			-- No-op at the moment, but useful for debugging.
		else
			if not warningsShown[v.event] then
				print(("unknown event at entry %d: %s"):format(i, v.event))
			end
			warningsShown[v.event] = true
		end
		if v.event == "Enter" or v.event == "Leave" or v.event == "CoroutineResume" or v.event == "CoroutineYield" then
			prev = v
		end
	end
	local multiplier = field == "timestamp" and 1e6 or 1
	for _, v in pairs(result) do
		for stack, value in pairs(v) do
			v[stack] = math.floor(value * multiplier + 0.5)
		end
	end
	return result
end

---@param trace TraceEntry[]
local function findOnUpdate(trace, offset)
	for i = offset, #trace do
		local v = trace[i]
		if v.event == "OnEvent" and v.functionName == "OnUpdate" then
			return i
		end
	end
	return nil
end


local function findLargestDelta(trace, offset, offsetEnd)
	local largest = 0
	local largestOffsetPos
	local lastTime = trace[offset].timestamp
	for i = offset + 1, offsetEnd do
		local v = trace[i]
		local delta = v.timestamp - lastTime
		lastTime = v.timestamp
		if delta > largest and trace[i - 1].stackEmpty then
			largest = delta
			largestOffsetPos = i
		end
	end
	return largestOffsetPos
end

---@param trace TraceEntry[]
---@return TrackedFrame
local function frameEntry(trace, first, last, id)
	local memOverhead, timeOverhead = 0, 0
	for i = first, last do
		memOverhead = memOverhead + math.max(trace[i].memoryOverhead, 0)
		timeOverhead = timeOverhead + trace[i].timeOverhead
	end
	---@class TrackedFrame
	local frame = {
		first = first,
		last = last,
		numEvents = last - first,
		time = trace[last].timestamp - trace[first].timestamp,
		memory = trace[last].memory - trace[first].memory,
		timeOverhead = timeOverhead,
		memOverhead = memOverhead,
		id = id,
		fps = 0, -- set by the next frame
		names = nil, -- set by the main script to give the files useful names
	}
	return frame
end

---@param trace TraceEntry[]
---@return TrackedFrame[]
function mod:FindSlowFrames(trace)
	---@type TrackedFrame[]
	local frames = {}
	local lastFrameStart = nil
	local lastOnUpdate = nil
	local inLoadingScreen = false
	local i = 0
	local nextFpsFromTime = 0
	while i < #trace do
		-- I'm not sure about the order in which OnUpdate handlers are invoked, it seems a bit inconsistent.
		-- But emperically this event seems to happen near the end of a frame, but the order between different handlers does not seem to be consistent.
		-- Anyhow, our definition of a frame is:
		--   A sequence of events containing exactly one OnUpdate call to the Perfy frame that starts/ends after/before the largest delta of the timestamp at an empty stack.
		-- Yes, it would obviously be better to just track the frame number in the trace (GetTime() uniquely identifies a frame),
		-- but I don't want to make the trace bigger for this niche use case.
		-- Algorithm to find the frames works as follows:
		--   1. Find the first 3 OnUpdate calls and use the largest two delta times between these there to mark the first frame (actually second real frame, but first frame is incomplete anyways)
		--   2. Find the next OnUpdate, the next frame end is at the highest delta between this and the last OnUpdate
		--   3. If we see a loading screen goto 1, otherwise goto to 2
		i = i + 1
		local v = trace[i]
		--[[
		new: 60555 to 99987
		frame 337: 60480 to 83748
		frame 338: 83749 to 100113
		60479: 0.002ms
		60480: frame 337 start, 0.032ms (!)
		60554: OnUpdate
		60555: frame end (16ms)
		83749: detected frame end (1ms)
		99987: OnUpdate
		100113: frame 338 end
		]]
		if i >= 60470 and i <= 100123 then
			local delta = v.timestamp - trace[i - 1].timestamp
			if delta > 0.001 or i == 60480 or i == 60481 or i == 60479 then
				--print(i, delta * 1000)
			end
			--if v.functionName == "OnUpdate" then print(i, "OnUpdate") end
		end
		if v.event == "OnEvent" and v.functionName == "OnUpdate" and not inLoadingScreen then
			if not lastFrameStart then
				local nextOnUpdate = findOnUpdate(trace, i + 1)
				local nextNextOnUpdate = nextOnUpdate and findOnUpdate(trace, nextOnUpdate + 1)
				if not nextNextOnUpdate or nextNextOnUpdate <= i + 4 then
					break
				end
				local frameFirst = findLargestDelta(trace, i, nextOnUpdate)
				local nextFrameFirst = findLargestDelta(trace, nextOnUpdate, nextNextOnUpdate)
				--print(i, "firstFrame", frameFirst, nextFrameFirst - 1)
				---@class TrackedFrame
				local frame = frameEntry(trace, frameFirst, nextFrameFirst - 1, #frames + 1)
				frames[#frames + 1] = frame
				if trace[nextNextOnUpdate].extraArg then
					frame.fps = 1 / trace[nextNextOnUpdate].extraArg
				end
				nextFpsFromTime = 1 / (v.timestamp - trace[nextOnUpdate].timestamp)
				lastFrameStart = nextFrameFirst
				lastOnUpdate = nextOnUpdate
				i = nextFrameFirst -- TODO: skips over loading screen detection if you somehow start right before a loading screen starts, but whatever
			else
				local nextFrameFirst = findLargestDelta(trace, lastOnUpdate, i)
				if not nextFrameFirst then
					break
				end
				---@class TrackedFrame
				local frame = frameEntry(trace, lastFrameStart, nextFrameFirst - 1, #frames + 1)
				frames[#frames + 1] = frame
				if v.extraArg then
					frame.fps = 1 / v.extraArg
				else -- to support old logs
					frame.fps = nextFpsFromTime
				end
				nextFpsFromTime = 1 / (v.timestamp - trace[lastOnUpdate].timestamp)
				lastFrameStart = nextFrameFirst
				lastOnUpdate = i
			end
		end
		-- Support old format where arg1 was embedded in function name
		if v.event == "OnEvent" and (v.functionName == "LOADING_SCREEN_ENABLED nil" or v.functionName == "LOADING_SCREEN_ENABLED") then
			inLoadingScreen = true
			lastFrameStart = nil
		elseif v.event == "OnEvent" and (v.functionName == "LOADING_SCREEN_DISABLED nil" or v.functionName == "LOADING_SCREEN_DISABLED") then
			inLoadingScreen = false
		end
	end
	return frames
end

---@param frames TrackedFrame[]
function mod:GetTopFrames(frames, num, cmp)
	local result = {}
	table.sort(frames, cmp)
	for i = 1, num do
		result[i] = frames[i]
	end
	table.sort(frames, function(e1, e2) return e1.id < e2.id end)
	return result
end

local function leftPadNums(tbl, precision)
	precision = precision or 0
	local maxLength = 0
	for i, v in ipairs(tbl) do
		tbl[i] = ("%." .. precision .. "f"):format(v)
		maxLength = math.max(maxLength, #tbl[i])
	end
	for i, v in ipairs(tbl) do
		tbl[i] = (" "):rep(maxLength - #v) .. v
	end
end

---@param frames TrackedFrame[]
function mod:PrintSlowFrames(frames, count)
	local ids, fps, events, times, memory = {}, {}, {}, {}, {}
	for i = 1, math.min(count, #frames) do
		local frame = frames[i]
		ids[#ids + 1] = frame.id
		fps[#fps + 1] = frame.fps
		events[#events + 1] = frame.numEvents
		times[#times + 1] = (frame.time - frame.timeOverhead) * 1000
		memory[#memory + 1] = math.max(frame.memory - frame.memOverhead, 0) / 1024 / 1024
	end
	leftPadNums(ids)
	leftPadNums(fps, 2)
	leftPadNums(events)
	leftPadNums(times, 2)
	leftPadNums(memory, 2)
	for i = 1, math.min(count, #frames) do
		print(("\tFrame %s: %s fps, %s events, %s ms total time, %s MiB memory allocs "):format(ids[i], fps[i], events[i], times[i], memory[i]))
	end
end

return mod
