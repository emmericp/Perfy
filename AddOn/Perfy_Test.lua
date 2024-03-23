local mockTime = 0
local function mockGetTime()
	return mockTime
end
GetTimePreciseSec = mockGetTime

local errorHandler = function(_) end
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

require "Perfy"

function TestHappyPath()
	Perfy_Clear()
	Perfy_Start()
	mockTime = 0.25
	Perfy_Trace(0, "Enter", "Fun1")
	mockTime = 1.25
	Perfy_Trace(1, "Enter", "Fun2")
	mockTime = 2
	Perfy_Trace_Leave("Leave", "Fun2")
	mockTime = 3
	Perfy_Trace_Leave("Leave", "Fun1")
	Perfy_Stop()

	-- FIXME: use some assertion library/test framework, what a mess
	assert(Perfy_Export.FunctionNames.Fun1 == 1)
	assert(Perfy_Export.FunctionNames.Fun2 == 2)
	assert(Perfy_Export.EventNames.Enter == 1)
	assert(Perfy_Export.EventNames.Leave == 2)
	assert(#Perfy_Export.Trace == 4)
	assert(Perfy_Export.Trace[1][1] == 0) -- Timestamp
	assert(Perfy_Export.Trace[1][2] == 1) -- Event
	assert(Perfy_Export.Trace[1][3] == 1) -- Function
	assert(Perfy_Export.Trace[1][4] == 0.25) -- Overhead
	assert(Perfy_Export.Trace[1][5] > 0) -- Memory
	assert(Perfy_Export.Trace[1][6] > 0) -- Memory overhead
	assert(Perfy_Export.Trace[3][1] == 2) -- Timestamp
	assert(Perfy_Export.Trace[3][2] == 2) -- Event
	assert(Perfy_Export.Trace[3][3] == 2) -- Function
	assert(Perfy_Export.Trace[3][4] == 0) -- Overhead (0 on leave because it's updated internally and the mock doesn't update)
	assert(Perfy_Export.Trace[3][5] > 0) -- Memory
	assert(Perfy_Export.Trace[3][6] > 0) -- Memory overhead
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
	local a, b = Perfy_Trace_Leave("Leave", "Fun1", "foo", "bar")
	Perfy_Stop()
	assert(a == "foo" and b == "bar")
end

function TestErrorHandlerHook()
	Perfy_Clear()
	Perfy_Start()
	geterrorhandler()("test")
	Perfy_Stop()

	assert(#Perfy_Export.Trace == 1)
end

function TestMultipleStarts()
	Perfy_Clear()
	Perfy_Start()
	Perfy_Trace(0, "Enter", "Fun1")
	Perfy_Trace(0, "Leave", "Fun1")
	Perfy_Trace(0, "Enter", "Fun3")
	Perfy_Stop()
	Perfy_Start()
	Perfy_Trace(0, "Enter", "Fun1")
	Perfy_Trace(0, "Enter", "Fun2")
	Perfy_Stop()
	assert(#Perfy_Export.Trace == 5)
	assert(#Perfy_Export.FunctionNames == 0) -- Double translation would enter a 1 = <something> entry
	assert(Perfy_Export.FunctionNames.Fun1 == 1)
	assert(Perfy_Export.FunctionNames.Fun3 == 2)
	assert(Perfy_Export.FunctionNames.Fun2 == 3)
end


TestHappyPath()
TestClear()
TestLeavePassthrough()
TestErrorHandlerHook()
TestMultipleStarts()
