SlashCmdList = {}

local running, runtime, cleared, logLoadingScreen, loadAddon
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

function Perfy_LoadAddOn(addon)
	loadAddon = addon
end

function Perfy_Run(func)
	func()
end

local function reset()
	running, runtime, cleared, logLoadingScreen, loadAddon = nil, nil, nil, nil, nil
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
SlashCmdList.PERFY("load")
assert(not loadAddon)
reset()
SlashCmdList.PERFY("load asdf")
assert(loadAddon == "asdf")

reset()
TEST_GLOBAL_VAR=false
SlashCmdList.PERFY("run TEST_GLOBAL_VAR=true")
assert(not running)
assert(TEST_GLOBAL_VAR)

reset()
local ok, err = pcall(SlashCmdList.PERFY, "run fail")
assert(not running)
assert(not ok)

reset()
SlashCmdList.PERFY("foo")
assert(not running)
