local analyze = require "Analyze"

local inFile = ...
if not inFile then
	return print("Usage: Main.lua <path to SavedVariables>/Perfy.lua")
end

local function writeFile(fileName, data)
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

local trace = analyze:LoadSavedVars(inFile)
local stacks = analyze:FlameGraph(trace)
writeFile("stacks-cpu.txt", stacks)

stacks = analyze:FlameGraph(trace, "memory", "memoryOverhead")
writeFile("stacks-memory.txt", stacks)
