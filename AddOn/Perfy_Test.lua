local mockTime = 0
local function mockGetTime()
	return mockTime
end
GetTimePreciseSec = mockGetTime

local lastError
local errorHandler = function(err) lastError = err end
function geterrorhandler()
	return errorHandler
end

function seterrorhandler(f)
	errorHandler = f
end

C_Timer = {
	After = function(_, f) f() end,
	NewTicker = function(_, f) f() end,
}

PERFY_TEST_ENVIRONMENT = true
require "Perfy"

function TestHappyPath()
	Perfy_Clear()
	mockTime = 0
	Perfy_Start()
	assert(Perfy_Running())
	mockTime = 0.25
	Perfy_Trace(0, "Enter", "Fun1")
	mockTime = 1.25
	Perfy_Trace(1, "Enter", "Fun2")
	mockTime = 2
	Perfy_Trace_Passthrough("Leave", "Fun2")
	mockTime = 3
	Perfy_Trace_Passthrough("Leave", "Fun1")
	Perfy_Stop()
	assert(not Perfy_Running())

	-- FIXME: use some assertion library/test framework, what a mess
	assert(Perfy_Export.FunctionNames["Perfy_Start Perfy/internal"] == 1)
	assert(Perfy_Export.FunctionNames.Fun1 == 2)
	assert(Perfy_Export.FunctionNames.Fun2 == 3)
	assert(Perfy_Export.FunctionNames["Perfy_Stop Perfy/internal"] == 4)
	assert(Perfy_Export.EventNames.PerfyStart == 1)
	assert(Perfy_Export.EventNames.Enter == 2)
	assert(Perfy_Export.EventNames.Leave == 3)
	assert(Perfy_Export.EventNames.PerfyStop == 4)
	assert(#Perfy_Export.Trace == 6)

	-- Entry 1: Start Perfy
	assert(Perfy_Export.Trace[1][1] == 0) -- Timestamp
	assert(Perfy_Export.Trace[1][2] == Perfy_Export.EventNames.PerfyStart) -- Event

	-- Entry 2: Enter Fun1
	assert(Perfy_Export.Trace[2][1] == 0) -- Timestamp
	assert(Perfy_Export.Trace[2][2] == Perfy_Export.EventNames.Enter) -- Event
	assert(Perfy_Export.Trace[2][3] == Perfy_Export.FunctionNames.Fun1) -- Function
	assert(Perfy_Export.Trace[2][4] == 0.25) -- Overhead
	assert(Perfy_Export.Trace[2][5] > 0) -- Memory
	assert(Perfy_Export.Trace[2][6] > 0) -- Memory overhead

	-- Entry 4: Leave Fun2
	assert(Perfy_Export.Trace[4][1] == 2) -- Timestamp
	assert(Perfy_Export.Trace[4][2] == Perfy_Export.EventNames.Leave) -- Event
	assert(Perfy_Export.Trace[4][3] == Perfy_Export.FunctionNames.Fun2) -- Function
	assert(Perfy_Export.Trace[4][4] == 0) -- Overhead (0 on leave because it's updated internally and the mock doesn't update)
	assert(Perfy_Export.Trace[4][5] > 0) -- Memory
	assert(Perfy_Export.Trace[4][6] > 0) -- Memory overhead

	-- Entry 6: Stop Perfy
	assert(Perfy_Export.Trace[6][1] == 3) -- Timestamp
	assert(Perfy_Export.Trace[6][2] == Perfy_Export.EventNames.PerfyStop) -- Event
end

function TestClear()
	Perfy_Clear()
	Perfy_Start()
	Perfy_Trace(0, "Enter", "Fun1")
	Perfy_Stop()
	assert(#Perfy_Export.Trace > 0)
	Perfy_Clear()
	assert(not Perfy_Export.Trace)
end

function TestLeavePassthrough()
	Perfy_Start()
	local a, b = Perfy_Trace_Passthrough("Leave", "Fun1", "foo", "bar")
	Perfy_Stop()
	assert(a == "foo" and b == "bar")
end

function TestErrorHandlerHook()
	Perfy_Clear()
	Perfy_Start()
	geterrorhandler()("test")
	Perfy_Stop()

	assert(#Perfy_Export.Trace == 3)
	assert(lastError == "test")
end

function TestMultipleStarts()
	Perfy_Clear()
	Perfy_Start()
	Perfy_Trace(0, "Enter", "Fun1")
	Perfy_Trace(0, "Leave", "Fun1")
	Perfy_Trace(0, "Enter", "Fun3")
	Perfy_Stop()
	assert(not Perfy_Running())
	Perfy_Start()
	Perfy_Trace(0, "Enter", "Fun1")
	Perfy_Trace(0, "Enter", "Fun2")
	Perfy_Stop()
	assert(#Perfy_Export.Trace == 9)
	 -- Double translation would enter a 1 = <something> entry because they see already translated entries as something to translate again
	assert(#Perfy_Export.FunctionNames == 0)
	assert(#Perfy_Export.EventNames == 0)
	assert(Perfy_Export.FunctionNames.Fun1 == 2)
	assert(Perfy_Export.FunctionNames.Fun3 == 3)
	assert(Perfy_Export.FunctionNames["Perfy_Stop Perfy/internal"] == 4)
	assert(Perfy_Export.FunctionNames.Fun2 == 5)
end

function TestLoadAddon()
	Perfy_Clear()
	local addonLoaded
	_G.LoadAddOn = function(addon)
		addonLoaded = addon
		return true
	end
	Perfy_LoadAddOn("FooAddOn")
	assert(addonLoaded == "FooAddOn")
	assert(#Perfy_Export.Trace == 4)
	assert(Perfy_Export.EventNames.LoadAddOn == 2)
	assert(Perfy_Export.EventNames.LoadAddOnFinished == 3)
	assert(Perfy_Export.FunctionNames.FooAddOn == 2)
end

function TestRunFunc()
	Perfy_Clear()
	local called = false
	local function f()
		called = true
	end
	Perfy_Run(f)
	assert(not Perfy_Running())
	assert(called)
	assert(#Perfy_Export.Trace == 2)

	Perfy_Clear()
	Perfy_Start()
	called = false
	Perfy_Run(f)
	assert(called)
	assert(Perfy_Running()) -- Doesn't stop if it was already running
	Perfy_Stop()
	assert(not Perfy_Running())
end

function TestRunFuncError()
	Perfy_Clear()
	local called = false
	local function f()
		called = true
		error("test")
	end
	local ok = pcall(Perfy_Run, f)
	assert(not Perfy_Running())
	assert(not ok)
	assert(called)
	assert(#Perfy_Export.Trace == 2)
end

TestHappyPath()
TestClear()
TestLeavePassthrough()
TestErrorHandlerHook()
TestMultipleStarts()
TestLoadAddon()
TestRunFunc()
TestRunFuncError()
