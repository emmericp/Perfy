local analyze = require "Analyze"

local inFile, frameCmd, frameIds = ...
if not inFile then
	return print("Usage: Main.lua <path to SavedVariables>/Perfy.lua [--frames <startFrameId>-<endFrameId>] [--frame <frameId>] [--split-frames]")
end

local function writeFile(fileNameSuffix, fullData)
	for frame, data in pairs(fullData) do
		local fileNames = {}
		if frame == "all" then
			fileNames[#fileNames + 1] = fileNameSuffix
		else
			for _, name in ipairs(frame.names) do
				fileNames[#fileNames + 1] = name .. "-" .. fileNameSuffix
			end
		end
		for _, fileName in ipairs(fileNames) do
			local file, err = io.open(fileName, "w+b")
			if not file then error(err) end
			local count = 0
			for k, v in pairs(data) do
				file:write(k)
				file:write(" ")
				file:write(tostring(v))
				file:write("\n")
				if v ~= 0 then
					count = count + 1
				end
			end
			file:close()
			print(("Wrote %d non-zero stacks to %s"):format(count, fileName))
		end
	end
end

local firstFrame, lastFrame, splitFrames
if frameCmd and frameCmd:match("^%-%-?frames?$") then
	if not frameIds then return print("expected frame numbers for " .. frameCmd) end
	firstFrame, lastFrame = frameIds:match("(%d*)%-?(%d*)$")
	if lastFrame == "" then
		lastFrame = firstFrame
	end
	firstFrame = tonumber(firstFrame)
	lastFrame = tonumber(lastFrame)
	if not firstFrame or not lastFrame then
		return print("couldn't parse " .. frameCmd .. " argument")
	end
elseif frameCmd and frameCmd:match("^%-%-?split%-frames$") then
	splitFrames = true
end

local trace = analyze:LoadSavedVars(inFile)

-- FIXME: properly split stack reconstruction and flame graph generation, this currently needs to be called prior to FindSlowFrames to have empty stack info
analyze:FlameGraph(trace, "timestamp", "timeOverhead")
local frames = analyze:FindSlowFrames(trace)
print("number of frames: ", #frames)
local topFramesByCpu = analyze:GetTopFrames(frames, 10, function(e1, e2) return e1.time - e1.timeOverhead > e2.time - e2.timeOverhead end)
local topFramesByMemory = analyze:GetTopFrames(frames, 10, function(e1, e2) return e1.memory - e1.memOverhead > e2.memory - e2.memOverhead end)

local stacksCpu, stacksMemory
if splitFrames then
	local topFrames = {}
	for i, v in ipairs(topFramesByCpu) do
		v.names = {("top-cpu-%d-frame-%d"):format(i, v.id)}
		topFrames[#topFrames + 1] = v
	end
	for i, v in ipairs(topFramesByMemory) do
		-- Frames can have multiple names because it's confusing if like half of your frames for a metric are missing because they happen to overlap with the other metric
		if v.names then
			v.names[#v.names + 1] = ("top-memory-%d-frame-%d"):format(i, v.id)
		else
			v.names = {("top-memory-%d-frame-%d"):format(i, v.id)}
		end
		topFrames[#topFrames + 1] = v
	end
	stacksCpu = analyze:FlameGraph(trace, "timestamp", "timeOverhead", nil, nil, topFrames)
	stacksMemory = analyze:FlameGraph(trace, "memory", "memoryOverhead", nil, nil, topFrames)
else
	stacksCpu = analyze:FlameGraph(trace, "timestamp", "timeOverhead", frames[firstFrame], frames[lastFrame])
	stacksMemory = analyze:FlameGraph(trace, "memory", "memoryOverhead", frames[firstFrame], frames[lastFrame])
end

if firstFrame then
	print("Only reporting trace entries " .. frames[firstFrame].first .. " to " .. frames[lastFrame].last)
else
	print("Top frames by CPU time:")
	analyze:PrintSlowFrames(topFramesByCpu, 10)
	print()
	print("Top frames by memory allocations:")
	analyze:PrintSlowFrames(topFramesByMemory, 10)
	print("Frame CPU time and memory may include uninstrumented code, run full analysis per-frame by using \"--split-frames\" to get one result per top frame or by selecting frames via \"--frames <startFrame>-<endFrame>\"")
end

writeFile("stacks-cpu.txt", stacksCpu)
writeFile("stacks-memory.txt", stacksMemory)
