-- LuaLS environment setup
local basePath = arg[0]:gsub("[/\\]*[^/\\]-$", "") -- The dir under which this file is
package.path = "./script/?.lua;./script/?/init.lua;./test/?.lua;./test/?/init.lua;"
package.path = package.path .. basePath .. "/?.lua;"
package.path = package.path .. basePath .. "/?/init.lua"
_G.log = require "log"
local fs = require "bee.filesystem"
ROOT = fs.path(fs.exe_path():parent_path():parent_path():string()) -- The dir under which LuaLS is
LUA_VER = "Lua 5.1"
TEST = true

local parser = require "parser"
local guide = require "parser.guide"

local instrument = require "Instrument"

---@param injections Injection[]
local function testInject(code, want, injections)
	local state = parser.compile(code, "Lua", "Lua 5.1")
	local got = table.concat(instrument:Inject(state, injections), "")
	if got ~= want then
		error(("Unexpected diff, want:\n%s\ngot:\n%s"):format(want, got), 2)
	end
end

testInject("local foo", "local foo", {})
testInject("local foo", "test local foo", {
	{pos = 0, text = "test"}
})
testInject("local foo", "local foo test", {
	{pos = 9, text = "test"}
})
testInject("foo()bar()", "foo() test bar()", {
	{pos = 5, text = "test"}
})
testInject("local foo\nlocal bar", "local foo test\nlocal bar", {
	{pos = 9, text = "test"}
})
---@diagnostic disable-next-line: err-esc
testInject("\xef\xbb\xbflocal foo", "\xef\xbb\xbftest local foo", {
	{pos = 0, text = "test"}
})

local function testInstrumentFunction(code, want)
	local state = parser.compile(code, "Lua", "Lua 5.1")
	local got = table.concat(instrument:InstrumentFunctions(state, function(action) return instrument:String(action) end), "")
	if got ~= want then
		error(("Unexpected diff, want:\n%s\ngot:\n%s"):format(want, got), 2)
	end
end

-- Various types of function definitions
testInstrumentFunction("function foo() end", "function foo() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); end")
testInstrumentFunction("local function foo() end", "local function foo() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); end")
testInstrumentFunction("local foo = function() end", "local foo = function() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); end")
testInstrumentFunction("print(function() end)", "print(function() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); end)")
testInstrumentFunction("function foo:bar() end", "function foo:bar() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); end")

-- Return statements with "trivial" expressions
testInstrumentFunction("function foo() return end", "function foo() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); return end")
testInstrumentFunction("function foo() do return end end", "function foo() Perfy_Trace(\"Enter\"); do Perfy_Trace(\"Leave\"); return end Perfy_Trace(\"Leave\"); end")
testInstrumentFunction("function foo() return 1 end", "function foo() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); return 1 end")
testInstrumentFunction("function foo() return 1, nil, false, 1.1, 'str' end", "function foo() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); return 1, nil, false, 1.1, 'str' end")
testInstrumentFunction("function foo() local x, y return x, y end", "function foo() Perfy_Trace(\"Enter\"); local x, y Perfy_Trace(\"Leave\"); return x, y end")
testInstrumentFunction("local x, y function foo() return x, y end", "local x, y function foo() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); return x, y end")

-- Return statements with "non-trivial" expressions
testInstrumentFunction("function foo() return x, y end", "function foo() Perfy_Trace(\"Enter\"); return Perfy_Trace_Passthrough(\"Leave\", x, y) end")
testInstrumentFunction("function foo() return function() end end", "function foo() Perfy_Trace(\"Enter\"); return Perfy_Trace_Passthrough(\"Leave\", function() Perfy_Trace(\"Enter\"); Perfy_Trace(\"Leave\"); end) end")
testInstrumentFunction("function foo() return 1 + 2 end", "function foo() Perfy_Trace(\"Enter\"); return Perfy_Trace_Passthrough(\"Leave\", 1 + 2) end")
testInstrumentFunction("function foo() return bar() end", "function foo() Perfy_Trace(\"Enter\"); return Perfy_Trace_Passthrough(\"Leave\", bar()) end")
testInstrumentFunction("function foo() return x.y end", "function foo() Perfy_Trace(\"Enter\"); return Perfy_Trace_Passthrough(\"Leave\", x.y) end")
testInstrumentFunction("function foo() return false, 1 + 1 end", "function foo() Perfy_Trace(\"Enter\"); return Perfy_Trace_Passthrough(\"Leave\", false, 1 + 1) end")

-- Comments
testInstrumentFunction("function foo()--comment\nend", "function foo() Perfy_Trace(\"Enter\"); --comment\nPerfy_Trace(\"Leave\"); end")

-- No-ops
testInstrumentFunction("local foo='function() end'", "local foo='function() end'")
testInstrumentFunction("do return end", "do return end")

-- Multiple nested functions
testInstrumentFunction([[
function foo()
	return function(bar)
		if x then return else
			return 5, 6, 7 end
	end
end
]], [[
function foo() Perfy_Trace("Enter");
	return Perfy_Trace_Passthrough("Leave", function(bar) Perfy_Trace("Enter");
		if x then Perfy_Trace("Leave"); return else
			Perfy_Trace("Leave"); return 5, 6, 7 end
	Perfy_Trace("Leave"); end)
end
]])

local function testGetFunctionName(code, want, fileName)
	local state = parser.compile(code, "Lua", "Lua 5.1")
	if fileName ~= false then
		fileName = fileName or "Interface/AddOns/test.lua"
		state.uri = "file://" .. fileName
	end
	local got
	instrument:InstrumentFunctions(state, function(_, f) got = f end)
	if got ~= want then
		error(("Unexpected diff, want:\n%s\ngot:\n%s"):format(want, got), 2)
	end
end

testGetFunctionName("function foo() end", "foo test.lua:1:0")
testGetFunctionName("function foo() end", "foo file://prefix/not/stripped.lua:1:0", "prefix/not/stripped.lua")
testGetFunctionName("function foo() end", "foo (unknown file):1:0", false)
testGetFunctionName("local function foo() end", "foo test.lua:1:6")
testGetFunctionName("local foo = function() end", "foo test.lua:1:12")
testGetFunctionName("local foo\nfoo = function() end", "foo test.lua:2:6")
testGetFunctionName("function foo:bar() end", "foo:bar test.lua:1:0")
testGetFunctionName("function foo.bar() end", "foo.bar test.lua:1:0")
testGetFunctionName("foo.bar = function() end", "foo.bar test.lua:1:10")
testGetFunctionName("foo['bar'] = function() end", "foo.bar test.lua:1:13")
testGetFunctionName("foo[5] = function() end", "foo.5 test.lua:1:9")
testGetFunctionName("foo[foo()] = function() end", "foo.? test.lua:1:13")
testGetFunctionName("foo().bar = function() end", "?.bar test.lua:1:12")
testGetFunctionName("foo = {bar = function() end}", "foo.bar test.lua:1:13")
testGetFunctionName("foo = {['bar'] = function() end}", "foo.bar test.lua:1:17")
testGetFunctionName("(foo)[foo()] = function() end", "(anonymous) test.lua:1:15")
testGetFunctionName("foo(function() end)", "(anonymous) test.lua:1:4")
testGetFunctionName("return function() end", "(anonymous) test.lua:1:7")

-- TODO: this is actually not ideal
testGetFunctionName("foo.bar.x = function() end", "bar.x test.lua:1:12")
-- TODO: maybe support this
testGetFunctionName("foo = {bar = {x = function() end}}", "(anonymous) test.lua:1:18")

local function testLocalLimits(code, want)
	local state = parser.compile(code, "Lua", "Lua 5.1")
	local lines = instrument:Instrument(code, "test.lua")
	assert(lines)
	local got = table.concat(lines, "")
	if got ~= want then
		error(("Unexpected diff, want:\n%s\ngot:\n%s"):format(want, got), 2)
	end
end

local locals = {}
for i = 1, 197 do
	locals[#locals + 1] = "local" .. i
end
local code = "local " .. table.concat(locals, ", ")
testLocalLimits(code, "--[[Perfy has instrumented this file]] local Perfy_GetTime, Perfy_Trace, Perfy_Trace_Passthrough = Perfy_GetTime, Perfy_Trace, Perfy_Trace_Passthrough; " .. code)

code = code .. "\nlocal localNumber198"
testLocalLimits(code, "--[[Perfy has instrumented this file]] " .. code)
