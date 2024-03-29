SlashCmdList = {}

local running, runtime, cleared, logLoadingScreen
function Perfy_Start(time)
	running = true
	runtime = time
end

function Perfy_Stop()
	running = false
	runtime = nil
end

function Perfy_Running()
	return running
end

function Perfy_Clear()
	cleared = true
end

function Perfy_LogLoadingScreen()
	logLoadingScreen = true
end

local function reset()
	running, runtime, cleared, logLoadingScreen = nil, nil, nil, nil
end

require "CLI"

reset()
SlashCmdList.PERFY("")
assert(running)
assert(runtime == nil)
SlashCmdList.PERFY("")
assert(not running)

reset()
SlashCmdList.PERFY("start")
assert(running)
assert(runtime == nil)
SlashCmdList.PERFY("stop")
assert(not running)
SlashCmdList.PERFY("clear")
assert(cleared)

reset()
SlashCmdList.PERFY("start 5")
assert(running)
assert(runtime == 5)

reset()
SlashCmdList.PERFY(" start	5  ")
assert(running)
assert(runtime == 5)

reset()
SlashCmdList.PERFY("10")
assert(running)
assert(runtime == 10)
SlashCmdList.PERFY("")
assert(not running)

reset()
SlashCmdList.PERFY("ls")
assert(logLoadingScreen)
reset()
SlashCmdList.PERFY("loadingscreen")
assert(logLoadingScreen)

reset()
SlashCmdList.PERFY("foo")
assert(not running)
