local analyze = require "Analyze"

-- Trace that would be generated by something like this:
--[[
function Fun1()	sleep(1) Fun2() sleep(1) end
function Fun2()	sleep(1) Fun3() sleep(1) Fun4() sleep(1) end
function Fun3() alloc(10) sleep(1) end
function Fun4() alloc(20) sleep(1) end
Fun1() -- Sleeps 7 seconds
sleep(10) -- this isn't traced
Fun4() -- Sleeps 1 second, covers that we don't account the 10 seconds we don't see here
]]
local testData = [[
local Fun1, Fun2, Fun3, Fun4 = 1, 2, 3, 4
local Enter, Leave = 1, 2
Perfy_Export = {
	FunctionNames = {
		Fun1 = Fun1, Fun2 = Fun2, Fun3 = Fun3, Fun4 = Fun4
	},
	EventNames = {
		Enter = Enter, Leave = Leave
	},
	Trace = { -- Tracing overhead is .25 seconds and 10 bytes
		{1.00, Enter, Fun1, 0.25, 10, 10},
		{2.25, Enter, Fun2, 0.25, 20, 10},
		{3.50, Enter, Fun3, 0.25, 30, 10},
		{4.75, Leave, Fun3, 0.25, 50, 10},
		{6.00, Enter, Fun4, 0.25, 60, 10},
		{7.25, Leave, Fun4, 0.25, 90, 10},
		{8.50, Leave, Fun2, 0.25, 100, 10},
		{9.75, Leave, Fun1, 0.25, 110, 10},
		{20.00, Enter, Fun4, 0.25, 110, 10},
		{21.25, Leave, Fun4, 0.25, 140, 10},
	}
}
]]

-- FIXME: this broke with the introduction of the Lua parser which can't handle the file above :/
local oldLoadfile = loadfile
function loadfile(file, ...)
	if file == "test" then
		local loaded
		---@diagnostic disable-next-line: redundant-parameter
		return load(function() if loaded then return nil end loaded = true return testData end, file, ...)
	else
		return oldLoadfile(file, ...)
	end
end

local trace = analyze:LoadSavedVars("test")
assert(#trace == 10)
assert(trace[5].timestamp == 6)
assert(trace[5].event == "Enter")
assert(trace[5].functionName == "Fun4")
assert(trace[5].timeOverhead == 0.25)
assert(trace[5].memory == 60)
assert(trace[5].memoryOverhead == 10)

local cpuStacks = analyze:FlameGraph(trace)
assert(cpuStacks["Unknown addon;Fun1"] == 2000000)
assert(cpuStacks["Unknown addon;Fun1;Fun2"] == 3000000)
assert(cpuStacks["Unknown addon;Fun1;Fun2;Fun3"] == 1000000)
assert(cpuStacks["Unknown addon;Fun1;Fun2;Fun4"] == 1000000)
assert(cpuStacks["Unknown addon;Fun4"] == 1000000)

local memStacks = analyze:FlameGraph(trace, "memory", "memoryOverhead")
assert(memStacks["Unknown addon;Fun1;Fun2;Fun3"] == 10)
assert(memStacks["Unknown addon;Fun1;Fun2;Fun4"] == 20)
assert(memStacks["Unknown addon;Fun4"] == 20)
