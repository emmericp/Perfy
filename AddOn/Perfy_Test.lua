local mockTime
local function mockGetTime()
	return mockTime
end
GetTimePreciseSec = mockGetTime

require "Perfy"

C_Timer = {After = function(_, f) f() end}

Perfy_Start()
mockTime = 0.25
Perfy_Trace(0, "Enter", "Fun1")
mockTime = 1.25
Perfy_Trace(1, "Enter", "Fun2")
mockTime = 2.25
Perfy_Trace(2, "Leave", "Fun2")
mockTime = 3.25
Perfy_Trace(3, "Leave", "Fun1")
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
assert(Perfy_Export.Trace[3][4] == 0.25) -- Overhead
assert(Perfy_Export.Trace[3][5] > 0) -- Memory
assert(Perfy_Export.Trace[3][6] > 0) -- Memory overhead
