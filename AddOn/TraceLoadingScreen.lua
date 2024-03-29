-- Uncomment this line to enable login loading screen tracing.
--Perfy_Start()

-- Login/reload loading screen event log looks like this:
-- 1. Run Lua files (Enter/Leave on main chunks)
-- 2. ADDON_LOADED fires
-- 3. PLAYER_LOGIN fires
-- 4. PLAYER_ENTERING_WORLD fires
-- 5. LOADING_SCREEN_DISABLED fires
-- 6. OnUpdate fires once
-- 7. SPELLS_CHANGED fires
--
-- We care about when the user considers the game running, a reasonable definition for running is "after the first frame has been drawn".
-- A reasonable close approximation for this is the start of the second (!) OnUpdate call because we are the first AddOn (they seem to be called in frame creation order).
-- Note that being off here by a frame isn't too bad because we only account time that we can "see" anyways, so the extra time during the two frames the game does other things doesn't show up anyways.
local counter = 0
local loginLoadingScreenFrame = CreateFrame("Frame")
loginLoadingScreenFrame:SetScript("OnUpdate", function(self)
	counter = counter + 1
	if counter == 2 then
		Perfy_Stop()
		self:Hide()
	end
end)
loginLoadingScreenFrame:Show()

-- Other loading screens look like this:
-- 1. LOADING_SCREEN_ENABLED fires
-- 2. OnUpdate continues firing normally
-- 3. PLAYER_LEAVING_WORLD fires
-- 4. OnUpdate continues firing normally
-- 5. PLAYER_ENTERING_WORLD fires and OnUpdate stops
-- 6. LOADING_SCREEN_DISABLED fires
-- 7. SPELLS_CHANGED fires
-- 8. OnUpdate continues firing normally
--
-- LOADING_SCREEN_ENABLED is a good point to start
-- The second OnUpdate after LOADING_SCREEN_DISABLED is a reasonable point to end following the same logic as above.
local loadingScreenFrame = CreateFrame("Frame")
loadingScreenFrame:RegisterEvent("LOADING_SCREEN_ENABLED")
loadingScreenFrame:RegisterEvent("LOADING_SCREEN_DISABLED")

local logNextLoadingScreen = false
local counter = 0
loadingScreenFrame:SetScript("OnEvent", function(self, event)
	if not logNextLoadingScreen then return end
	if event == "LOADING_SCREEN_ENABLED" then
		Perfy_Start()
	elseif event == "LOADING_SCREEN_DISABLED" then
		logNextLoadingScreen = false
		counter = 0
		self:Show()
	end
end)
loadingScreenFrame:SetScript("OnUpdate", function(self)
	counter = counter + 1
	if counter == 2 then
		Perfy_Stop()
		self:Hide()
	end
end)

-- Trace a non-login loading screen.
function Perfy_LogLoadingScreen()
	print("[Perfy] Next loading screen will be logged by Perfy.")
	print("[Perfy] This will not work for loading screens due to UI reload or logging in. See file TraceLoadingScreen.lua for instructions to trace these initial loading screens.")
	logNextLoadingScreen = true
end
