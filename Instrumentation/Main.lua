-- LuaLS environment setup
local basePath = arg[0]:gsub("[/\\]*[^/\\]-$", "") -- The dir under which this file is
package.path = "./script/?.lua;./script/?/init.lua;./test/?.lua;./test/?/init.lua;"
package.path = package.path .. basePath .. "/?.lua;"
package.path = package.path .. basePath .. "/?/init.lua"
_G.log = require "log"
local fs = require "bee.filesystem"
ROOT = fs.path(fs.exe_path():parent_path():parent_path():string()) -- The dir under which LuaLS is
LUA_VER = "Lua 5.1"

local instrument = require "Instrument"
local toc = require "TocHandler"

if #arg < 1 then
	print("Usage: " .. arg[0] .. " <toc files>")
	return
end

local function stripPathPrefix(path)
	return path:gsub("^.*Interface[/\\]AddOns[/\\]", "")
end

local seenFiles = {}
local function handleTocFile(fileName)
	print("Instrumenting AddOn " .. stripPathPrefix(fileName))
	local file, err = io.open(fileName, "r")
	if not file then error(err) end

	local lines = {}
	for line in file:lines() do
		-- Why are line ending differences between Windows and others still a problem in 2024?
		lines[#lines + 1] = line:match("(.-)\r?$")
	end
	file:close()

	toc:InjectDependency(lines)

	file, err = io.open(fileName, "w+")
	if not file then error(err) end
	for _, line in ipairs(lines) do
		file:write(line)
		file:write("\n")
	end
	file:close()

	local dir = fileName:gsub("[^/\\]-$", "")
	local files = toc:FindFiles(lines, dir)

	for _, fileName in ipairs(files) do
		if not seenFiles[fileName] then  -- avoids errors about files being referenced multiple times (by tocs for different game versions)
			instrument:InstrumentFile(fileName) -- TODO: handle failure gracefully to not fail completely on a single bad addon
			seenFiles[fileName] = true
		end
	end
end

for _, fileName in ipairs(arg) do
	if fileName:match("Perfy.toc$") then
		print("File " .. fileName .. " seems to belong to Perfy itself -- skipping.")
	else
		handleTocFile(fileName)
	end
end


