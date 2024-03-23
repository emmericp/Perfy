local mod = {}

local parser = require "parser"
local guide = require "parser.guide"

local function splitPos(pos)
	return math.floor(pos / 10000) + 1, pos % 10000
end

-- Yeah, this is a thing and some AddOns have this in their files
-- DBM used to set that too -- in like 2008 when some editors wouldn't default to UTF-8 without this.
---@diagnostic disable-next-line: err-esc -- The whole project is setup as Lua 5.1 (WoW Lua version), but everything that runs in LuaLS is actually Lua 5.3
local utf8Bom = "\xef\xbb\xbf"

local function injectLine(line, inj, offs)
	local _, injPos = splitPos(inj.pos)
	injPos = injPos + offs
	local prePadding = not inj.skipPrepadding and injPos > 0 and line:sub(injPos, injPos):match("[^%s]") and line:sub(0, injPos) ~= utf8Bom and " " or ""
	local postPadding = injPos < #line and line:sub(injPos + 1, injPos + 1):match("[^%s]") and " " or ""
	local injText = prePadding .. inj.text .. postPadding
	offs = offs + #injText
	return line:sub(0, injPos) .. injText .. line:sub(injPos + 1), offs
end

---@class Injection
---@field pos number Position to inject at in LuaLS format
---@field text string What to inject
---@field skipPrePadding boolean? Don't add a space in front of the injection

---@param state parser.state
---@param injections Injection[]
function mod:Inject(state, injections)
	local buf = {}
	local injIndex = 1
	local last = 0
	table.sort(injections, function(e1, e2) return e1.pos < e2.pos end)
	local hasUtf8Bom = state.lua:match("^" .. utf8Bom)
	for i = 0, #state.lines + 1 do
		local v = state.lines[i] or #state.lua + 1
		local line = state.lua:sub(last, v - 1)
		local inj = injections[injIndex]
		local offs = 0
		if hasUtf8Bom and inj and splitPos(inj.pos) == 1 then
			offs = offs + 3
		end
		while inj and splitPos(inj.pos) == i do
			line, offs = injectLine(line, inj, offs)
			injIndex = injIndex + 1
			inj = injections[injIndex]
		end
		buf[#buf + 1] = line
		last = v
	end
	return buf
end

local function stripFilePrefix(file)
	return file:match("^file://.-Interface/AddOns/(.*)") or file
end

-- TODO: doesn't support nested tables, let's see if this turns out to be relevant
local function getFunctionName(node, fileName)
	local line, pos = splitPos(node.start)
	local parent = node.parent
	local name = "(anonymous)" ---@type string?
	if parent.type == "setglobal" or parent.type == "setlocal" or parent.type == "local" then
		name = guide.getKeyName(parent)
	elseif parent.type == "setmethod" then
		name = guide.getKeyName(parent.node) .. ":" .. guide.getKeyName(parent)
	elseif parent.type == "setfield" or parent.type == "setindex" then
		local tbl = guide.getKeyName(parent.node)
		local key = guide.getKeyName(parent)
		if tbl or key then
			name = (tbl or "?") .. "." .. (key or "?")
		end
	elseif parent.type == "tablefield" or parent.type == "tableindex" then
		local key = guide.getKeyName(parent)
		local tableVar = parent.parent.parent
		if tableVar.type == "setglobal" or tableVar.type == "setlocal" or tableVar.type == "local" then
			name = guide.getKeyName(tableVar) .. "." .. (key or "?")
		end
	end
	return name .. " " .. stripFilePrefix(fileName) .. ":" .. line .. ":" .. pos
end

function mod:String(str)
	return ("%q"):format(str)
end

---@param state parser.state
---@param argFunc fun(action: string, funcName: string, node: parser.object, passthrough: boolean?): ...
---@param injections Injection[]?
function mod:InstrumentFunctions(state, argFunc, injections)
	-- Note on semicolons:
	-- Normal trace injections need them to avoid the Lua grammar ambiguity for function call vs. new statement,
	-- e.g., foo()\n(bar).x = 5 (which is a parser error without a semicolon at the end of the line).
	-- Injections wrapping returns must not add a semicolon because a return must be the last statement in a block
	-- and if there was already a semicolon we would introduce an additional emtpy statement which is invalid.
	local injections = injections or {}
	guide.eachSourceType(state.ast, "function", function(node)
		local funcName = getFunctionName(node, state.uri or "(unknown file)")
		local enterArgs = argFunc and {argFunc("Enter", funcName, node)} or {}
		local leaveArgs = argFunc and {argFunc("Leave", funcName, node)} or {}
		local passthroughLeaveArgs = argFunc and {argFunc("Leave", funcName, node, true)} or {}
		injections[#injections + 1] = {
			pos = node.args.finish,
			text = "Perfy_Trace(" .. table.concat(enterArgs, ", ") .. ");"
		}
		if not node[#node] or node[#node].type ~= "return" then
			injections[#injections + 1] = {
				pos = node.finish - 3,
				text = "Perfy_Trace(" .. table.concat(leaveArgs, ", ") .. ");"
			}
		end
		if node.returns then
			for k, v in pairs(node.returns) do
				if #v > 0 then
					injections[#injections + 1] = {
						pos = v[1].start,
						text = "Perfy_Trace_Leave(" .. table.concat(passthroughLeaveArgs, ", ") .. ","
					}
					injections[#injections + 1] = {
						pos = v[#v].finish,
						text = ")",
						skipPrepadding = true
					}
				else
					injections[#injections + 1] = {
						pos = v.start,
						text = "Perfy_Trace(" .. table.concat(leaveArgs, ", ") .. ");"
					}
				end
			end
		end
	end)
	return self:Inject(state, injections)
end

local perfyTag = "--[[Perfy has instrumented this file]]"
function mod:Instrument(code, fileName, retryAfterLocalLimitExceeded)
	if code:sub(1, #perfyTag) == perfyTag then
		return nil, "is already instrumented, skipping"
	end
	local state = parser.compile(code, "Lua", "Lua 5.1")
	state.uri = "file://" .. fileName
	---@type Injection[]
	local injections = {}
	if not retryAfterLocalLimitExceeded then
		injections[#injections + 1] = {pos = 0, text = perfyTag .. " local Perfy_GetTime, Perfy_Trace, Perfy_Trace_Leave = Perfy_GetTime, Perfy_Trace, Perfy_Trace_Leave;"}
	else
		print("File " .. fileName .. " hit > 200 local variables at line " .. splitPos(retryAfterLocalLimitExceeded.start) .. " after injecting. Skipping local cache, Perfy's overhead for this file will be higher.")
		injections[#injections + 1] = {pos = 0, text = perfyTag}
	end
	local lines = self:InstrumentFunctions(state, function(action, funcName, _, passthrough)
		if passthrough then
			return self:String(action), self:String(funcName)
		else
			return "Perfy_GetTime()", self:String(action), self:String(funcName)
		end
	end, injections)
	local newState = parser.compile(table.concat(lines, ""), "Lua", "Lua 5.1")
	-- Lua only allows 200 local variables, so we can only inject our locals at the top if the file doesn't already define more than this.
	-- And yes, there are AddOns out there which are at exactly this limit: Plater and NovaWorldBuffs
	for _, v in ipairs(newState.errs) do
		if v.type == "LOCAL_LIMIT" and not retryAfterLocalLimitExceeded then
			return self:Instrument(code, fileName, v)
		end
	end
	if #newState.errs > #state.errs then
		local newError = newState.errs[#state.errs + 1]
		for i = 1, #state.errs do
			if newState.errs[i].type ~= state.errs[i].type then
				newError = newState.errs[i]
			end
		end
		print("File " .. fileName .. " reported an unexpected new parsing error after instrumentation: " .. newError.type .. " at line " .. splitPos(newError.start))
	end
	return lines
end

function mod:InstrumentFile(fileName)
	if not fileName:lower():match(".lua$") then
		print("File " .. fileName .. " does not seem to be a Lua file, skipping.")
		return
	end
	local file, err = io.open(fileName, "r")
	if not file then error(err) end
	local code = file:read("*a")
	file:close()
	local output, err = self:Instrument(code, fileName)
	if not output then
		print("Could not instrument " .. fileName .. ": " .. err)
		return
	end
	file, err = io.open(fileName, "w+")
	if not file then error(err) end
	for _, line in ipairs(output) do
		file:write(line) -- line already contains the original line ending
	end
	file:close()
end

return mod
