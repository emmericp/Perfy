local function usage()
	print("[Perfy] Usage:")
	print("/perfy start [time] -- Starts Perfy and optionally automatically stops it after time seconds.")
	print("/perfy stop -- Stops Perfy.")
	print("/perfy [time] -- Toggles Perfy, if starting optionally stops after time seconds.")
	print("/perfy ls|loadingscreen -- Starts Perfy once the next loading screen is shown, stops once loading completes.")
	print("/perfy clear -- Deletes all collected traces.")
end

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
		if arg1:lower() == "start" then
			Perfy_Start(tonumber(arg2))
		elseif arg1:lower() == "stop" then
			Perfy_Stop()
		elseif arg1:lower() == "clear" then
			Perfy_Clear()
		elseif arg1:lower() == "ls" or arg1:lower() == "loadingscreen" then
			Perfy_LogLoadingScreen()
		else
			usage()
		end
	end
end
