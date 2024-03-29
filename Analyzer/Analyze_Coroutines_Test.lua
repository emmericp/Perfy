local analyze = require "Analyze"

-- Trace that would be generated by something like this:
--[[
function Fun1()	sleep(1) coroutine.yield() Fun2() end
function Fun2() sleep(2) coroutine.yield() end
function Fun3()	sleep(1) coroutine.yield() Fun4() end
function Fun4() sleep(2) coroutine.yield() end

local c1, c2 = coroutine.create(Fun1), coroutine.create(Fun3)

function Run()
	while <something> do
		sleep(0.1)
		coroutine.resume(c1)
		sleep(0.1)
		coroutine.resume(c2)
	end
end
]]
local testData = [[
local Fun1, Fun2, Fun3, Fun4, Run, Cr1, Cr2 = 1, 2, 3, 4, 5, 6, 7
local Enter, Leave, CoroutineResume, CoroutineYield = 1, 2, 3, 4
Perfy_Export = {
	FunctionNames = {
		Fun1 = Fun1, Fun2 = Fun2, Fun3 = Fun3, Fun4 = Fun4, Run = Run, Cr1 = Cr1, Cr2 = Cr2
	},
	EventNames = {
		Enter = Enter, Leave = Leave, CoroutineResume = CoroutineResume, CoroutineYield = CoroutineYield
	},
	Trace = {
		{0.0, Enter, Run, 0, 0, 0},
		{0.1, CoroutineResume, Cr1, 0, 0, 0},
		{0.1, Enter, Fun1, 0, 0, 0},
		{1.1, CoroutineYield, Cr1, 0, 0, 0},
		{1.2, CoroutineResume, Cr2, 0, 0, 0},
		{1.2, Enter, Fun3, 0, 0, 0},
		{2.2, CoroutineYield, Cr2, 0, 0, 0},
		{2.3, CoroutineResume, Cr1, 0, 0, 0},
		{2.3, Enter, Fun2, 0, 0, 0},
		{4.3, CoroutineYield, Cr1, 0, 0, 0},
		{4.4, CoroutineResume, Cr2, 0, 0, 0},
		{4.4, Enter, Fun4, 0, 0, 0},
		{6.4, CoroutineYield, Cr2, 0, 0, 0},
		{6.5, CoroutineResume, Cr1, 0, 0, 0},
		{6.5, Leave, Fun2, 0, 0, 0},
		{6.5, Leave, Fun1, 0, 0, 0},
		{6.6, CoroutineResume, Cr2, 0, 0, 0},
		{6.6, Leave, Fun4, 0, 0, 0},
		{6.6, Leave, Fun3, 0, 0, 0},
		{6.6, Leave, Run, 0, 0, 0},
	}
}
]]

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
local cpuStacks = analyze:FlameGraph(trace)

assert(cpuStacks["Unknown addon;Run"] == 0.6e6)
assert(cpuStacks["Unknown addon;Run;Fun1"] == 1e6)
assert(cpuStacks["Unknown addon;Run;Fun1;Fun2"] == 2e6)
assert(cpuStacks["Unknown addon;Run;Fun3"] == 1e6)
assert(cpuStacks["Unknown addon;Run;Fun3;Fun4"] == 2e6)
