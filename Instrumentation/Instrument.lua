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
	local _, injPos = splitPos(inj.pos < math.huge and inj.pos or 0)
	injPos = injPos + offs
	local prePadding = not inj.skipPrepadding and injPos > 0 and not inj.text:match("^%s") and line:sub(injPos, injPos):match("[^%s]") and line:sub(0, injPos) ~= utf8Bom and " " or ""
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
	-- End-of-file injections aren't in the loop above they refer to line infinity which doesn't exist, this is to avoid problems if the last line is > 10k characters long.
	local suffix = ""
	local offs = 0
	for i = injIndex, #injections do
		suffix, offs = injectLine(suffix, injections[i], offs)
	end
	buf[#buf + 1] = suffix
	return buf
end

local function stripFilePrefix(file)
	return file:match("^file://.-Interface/AddOns/(.*)") or file
end

local function getTableIndexPretty(key)
	if type(key) == "string" and key:match("^[%a_][%w_]*$")  then
		return "." .. key
	elseif key == nil then
		return ".?"
	else
		return ("[%q]"):format(key)
	end
end

-- TODO: doesn't support nested tables, let's see if this turns out to be relevant
local function getFunctionName(node, fileName)
	local line, pos = splitPos(node.start)
	local parent = node.parent
	if not parent then
		return "(main chunk) " .. stripFilePrefix(fileName)
	end
	local name = "(anonymous)" ---@type string?
	if parent.type == "setglobal" or parent.type == "setlocal" or parent.type == "local" then
		name = guide.getKeyName(parent)
	elseif parent.type == "setmethod" then
		name = guide.getKeyName(parent.node) .. ":" .. guide.getKeyName(parent)
	elseif parent.type == "setfield" or parent.type == "setindex" then
		local tbl = guide.getKeyName(parent.node)
		local key = guide.getKeyName(parent)
		if tbl or key then
			name = (tbl or "?") .. getTableIndexPretty(key)
		end
	elseif parent.type == "tablefield" or parent.type == "tableindex" then
		local key = guide.getKeyName(parent)
		local tableVar = parent.parent.parent
		if tableVar.type == "setglobal" or tableVar.type == "setlocal" or tableVar.type == "local" then
			name = guide.getKeyName(tableVar) .. getTableIndexPretty(key)
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
function mod:InstrumentFunctions(state, argFunc, injections, skipMainChunk)
	-- Note on semicolons:
	-- Normal trace injections need them to avoid the Lua grammar ambiguity for function call vs. new statement,
	-- e.g., foo()\n(bar).x = 5 (which is a parser error without a semicolon at the end of the line).
	-- Injections wrapping returns must not add a semicolon because we are replacing an expression, not a statement.
	-- If we the return already has a semicolon we would generate "return foo();;" which is invalid because empty statements are invalid.
	injections = injections or {}
	guide.eachSourceTypes(state.ast, {"function", "main"}, function(node)
		if node.type == "main" and skipMainChunk then return end
		local funcName = getFunctionName(node, state.uri or "(unknown file)")
		local enterArgs = argFunc and {argFunc("Enter", funcName, node)} or {}
		local leaveArgs = argFunc and {argFunc("Leave", funcName, node)} or {}
		local passthroughLeaveArgs = argFunc and {argFunc("Leave", funcName, node, true)} or {}
		if node.type ~= "main" then
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
		else
			-- Main chunk enter trace gets injected by file preamble.
			-- Main implicit exit point is just the last line, but unlike functions we don't have an "end" token here, so we need a newline to avoid conflicts with trailing comments
			if not node[#node] or node[#node].type ~= "return" then
				injections[#injections + 1] = {
					pos = math.huge, -- Don't use node.finish here, it will fail if the last line is longer than 10k characters
					text = "\nPerfy_Trace(" .. table.concat(leaveArgs, ", ") .. ");"
				}
			end
		end
		if node.returns then
			for k, ret in pairs(node.returns) do
				-- Two ways to instrument returns:
				-- 1. return Perfy_Trace_Passthrough("Leave", ...)
				-- 2. Perfy_Trace(Perfy_GetTime(), "Leave") return ...
				-- Neither of them is perfect
				-- (1) Samples the current time inside Perfy, i.e., the time to call into Perfy is incorrectly accounted to the calling function, see Accuracy.md for how this can skew small functions.
				-- (2) Samples the current time before evaluating the return expression, this means the time for the return expression is accounted to the calling function.
				-- Neither is perfect, the logic below picks (2) if the return expressions are deemed trivial (constants or locals) and (1) otherwise.
				-- We could expand what we consider trivial (e.g., are closure creations trivial? are things like binary_op(local, literal) trivial?).
				-- But the fundamental problem is unsolvable in a source-to-source translation: we can't capture the time between calling into Perfy but immediately before returning in the general case.
				-- The reason are tail calls that can return varargs: "return foo()" can't be translated to "return Perfy_Trace_Passthrough("Leave", foo(), Perfy_GetTime())" (and time sampling needs to be last, args are evaluated left-to-right).
				-- One potential improvement would be having tracer functions for known number of return parameters, e.g. return foo(), 5 could be translated to Perfy_Trace_Passthrough2("Leave", foo(), 5, GetTime()).
				-- But that'd either be an injected getglobal (but correctly accounted for) or an extra variable (and the 200 local limit is already triggering on a few files).
				local returnHasNonTrivialExpression = false
				for i, v in ipairs(ret) do
					while v.type == "paren" do
						v = v.exp
					end
					if v.type ~= "getlocal" and v.type ~= "string" and v.type ~= "boolean" and v.type ~= "nil" and v.type ~= "number" and v.type ~= "integer" then
						returnHasNonTrivialExpression = true
						break
					end
				end
				if returnHasNonTrivialExpression then
					injections[#injections + 1] = {
						pos = ret[1].start,
						text = "Perfy_Trace_Passthrough(" .. table.concat(passthroughLeaveArgs, ", ") .. ","
					}
					injections[#injections + 1] = {
						pos = ret[#ret].finish,
						text = ")",
						skipPrepadding = true
					}
				else
					injections[#injections + 1] = {
						pos = ret.start,
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
	local perfyEnterFile = (" Perfy_Trace(Perfy_GetTime(), %q, %q);"):format("Enter", getFunctionName(state.ast, state.uri))
	---@type Injection[]
	local injections = {}
	if not retryAfterLocalLimitExceeded then
		injections[#injections + 1] = {pos = 0, text = perfyTag .. " local Perfy_GetTime, Perfy_Trace, Perfy_Trace_Passthrough = Perfy_GetTime, Perfy_Trace, Perfy_Trace_Passthrough;" .. perfyEnterFile}
	else
		-- TODO: As we're adding more and more functions it might make sense to support partially adding
		print("File " .. fileName .. " hit > 200 local variables at line " .. splitPos(retryAfterLocalLimitExceeded.start) .. " after injecting. Skipping local cache, Perfy's overhead for this file will be higher.")
		injections[#injections + 1] = {pos = 0, text = perfyTag .. perfyEnterFile}
	end
	local lines = self:InstrumentFunctions(state, function(action, funcName, _, passthrough)
		if passthrough then
			return self:String(action), self:String(funcName)
		else
			return "Perfy_GetTime()", self:String(action), self:String(funcName)
		end
	end, injections)
	local newState = parser.compile(table.concat(lines, ""), "Lua", "Lua 5.1")
	-- Lua 5.1 only allows 200 local variables, so we can only inject our locals at the top if the file doesn't already define more than this.
	-- And yes, there are AddOns out there which are at exactly this limit: Plater and NovaWorldBuffs
	-- Also, there is a limit of 60 upvalues per function that we may hit with the injections, but I haven't encountered this yet for any real code.
	-- Unfortunately LuaLS currently does not support this, so this case is currently unhandled, see https://github.com/LuaLS/lua-language-server/issues/2578.
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
				break
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
	-- TODO: this is case sensitive on reasonable filesystems, but Lua in WoW it isn't case sensitive.
	local file, err = io.open(fileName, "r")
	if not file then error(err) end
	local code = file:read("*a")
	file:close()
	local output, err = self:Instrument(code, fileName)
	if not output then
		print("Could not instrument " .. fileName .. ": " .. err)
		return
	end
	file, err = io.open(fileName, "w+b")
	if not file then error(err) end
	for _, line in ipairs(output) do
		file:write(line) -- line already contains the original line ending
	end
	file:close()
end

return mod
