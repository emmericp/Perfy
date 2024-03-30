local function usage()
	print("[Perfy] Usage:")
	print("/perfy start [time] -- Starts Perfy and optionally automatically stops it after time seconds.")
	print("/perfy stop -- Stops Perfy.")
	print("/perfy [time] -- Toggles Perfy, if starting optionally stops after time seconds.")
	print("/perfy ls|loadingscreen -- Starts Perfy once the next loading screen is shown, stops once loading completes.")
	print("/perfy load <addon name> -- Loads an on-demand loadable addon and traces its loading process.")
	print("/perfy run <code> -- Starts Perfy, runs the given code, and stops Perfy again.")
	print("/perfy clear -- Deletes all collected traces.")
end

local loadstring = loadstring or load -- Lua 5.2+ support to not fail tests if running under a later Lua version

SLASH_PERFY1 = '/perfy'
function SlashCmdList.PERFY(msg)
	local arg1, arg2 = msg:match("%s*([^%s]+)%s*([^%s]*)")
	if not arg1 or tonumber(arg1) then
		if not Perfy_Running() then
			Perfy_Start(tonumber(arg1))
		else
			Perfy_Stop()
		end
	else
		arg1 = arg1:lower()
		if arg1 == "start" then
			Perfy_Start(tonumber(arg2))
		elseif arg1 == "stop" then
			Perfy_Stop()
		elseif arg1 == "clear" then
			Perfy_Clear()
		elseif arg1 == "ls" or arg1:lower() == "loadingscreen" then
			Perfy_LogLoadingScreen()
		elseif arg1 == "load" and arg2 ~= "" then
			Perfy_LoadAddOn(arg2)
		elseif arg1 == "run" and arg2 ~= "" then
			local code = msg:match("%s*[^%s]+%s+([^%s]+)")
			local func, err = loadstring(code, "(/perfy run)")
			if not func then
				error(err)
			end
			Perfy_Run(func)
		else
			usage()
		end
	end
end
