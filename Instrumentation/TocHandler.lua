local mod = {}

function mod:InjectDependency(lines, dep)
	dep = dep or "!!!Perfy"
	local lastMetadataLine = 0
	local foundDependencyEntry = false
	local foundPerfyMetadata = false
	for i, line in ipairs(lines) do
		local key, value = line:match("^##%s*([^:%s]+)%s*:%s*(.-)%s*$")
		if key and value then
			lastMetadataLine = i
			if key == "Dependencies" then
				foundDependencyEntry = true
				local foundDep = false
				for entry in value:gmatch("([^%s,]+)") do
					if entry == dep then
						foundDep = true
					end
				end
				if not foundDep then
					lines[i] = line .. (value ~= "" and ", " or "") .. dep
				end
			end
			if key == "X-Perfy-Instrumented" then
				foundPerfyMetadata = true
			end
		end
	end
	if not foundPerfyMetadata then
		table.insert(lines, lastMetadataLine + 1, "## X-Perfy-Instrumented: true")
	end
	if not foundDependencyEntry then
		table.insert(lines, lastMetadataLine + 1, "## Dependencies: " .. dep)
	end
end

-- "Mom, can we have an XML parser?" -- "No, we have XML parser at home."
-- XML parser at home:
local function parseXml(fileName, addonBasePath, files)
	local dir = fileName:gsub("[^/\\]-$", "")
	local file, err = io.open(fileName, "r")
	if not file then error(err) end -- TODO: could handle gracefully to not fail completely on one invalid toc
	local xml = file:read("*a")
	file:close()
	local luaFiles = {}
	-- "No, you can't parse HTML/XML like that" -- "Haha, regex goes <br/?>"
	xml = xml:gsub("<!%-%-(.-)%-%->", "")
	for ref in xml:gmatch("<%s*[iI][nN][cC][lL][uU][dD][eE]%s+[fF][iI][lL][eE]%s*=%s*(.-)%s*/?%s*>") do
		local delim = ref:sub(1, 1)
		if delim == "\"" or delim == "'" then
			ref = ref:sub(2, -2)
		end
		ref = ref:gsub("\\", "/")
		if ref:lower():match("%.xml$") then
			parseXml(dir .. ref, addonBasePath, files)
		elseif ref:lower():match("%.lua$") then -- Yes, this is apparently valid
			luaFiles[#luaFiles + 1] = ref
		else
			print("File " .. fileName .. " references file " .. ref .. " which is neither XML nor Lua, ignoring.")
		end
	end
	for ref in xml:gmatch("<%s*[sS][cC][rR][iI][pP][tT]%s+[fF][iI][lL][eE]%s*=%s*(.-)%s*/?%s*>") do
		local delim = ref:sub(1, 1)
		if delim == "\"" or delim == "'" then
			ref = ref:sub(2, -2)
		end
		ref = ref:gsub("\\", "/")
		luaFiles[#luaFiles+1] = ref
	end
	for _, ref in ipairs(luaFiles) do
		local fileRelToXml = io.open(dir .. ref, "r")
		local fileRelToToc = io.open(addonBasePath .. ref, "r")
		if fileRelToXml then
			fileRelToXml:close()
			files[#files + 1] = dir .. ref
		end
		if fileRelToToc then -- Apparently this is valid, e.g., RXPGuides does this for its database files
			fileRelToToc:close()
			files[#files + 1] = addonBasePath .. ref
		end
		if not fileRelToXml and not fileRelToToc then
			print("File " .. fileName .. " references unknown file " .. ref)
		end
	end
end

function mod:FindFiles(lines, dir)
	local files = {}
	for _, line in ipairs(lines) do
		if not line:match("^%s*#") and not line:match("^%s*$") then
			local file = line:gsub("^%s*(.-)%s*$", "%1"):gsub("\\", "/")
			if file:match("%.[xX][mM][lL]$") then
				parseXml(dir .. file, dir, files)
			else
				files[#files + 1] = dir .. file
			end
		end
	end
	return files
end

return mod
