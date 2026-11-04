-- Lua twin of bench.ms for LuaJIT -joff, LuaJIT -jon and Lua 5.4: same rows, same rounds, same columns.
-- os.clock is process CPU time; Lua has no portable wall clock.

local MIN_ROUND_MS, ROUNDS = 250.0, 3
local clock = os.clock

local function round(op)
	local calls = 1
	while true do
		local start = clock()
		for _ = 1, calls do op() end
		local elapsed = (clock() - start) * 1000.0
		if elapsed >= MIN_ROUND_MS then return elapsed / calls end
		calls = elapsed < 1.0 and calls * 16 or math.ceil(calls * (MIN_ROUND_MS * 1.2 / elapsed))
	end
end

local function fixed(value, digits)
	local scale = 10 ^ digits
	return string.format("%.15g", math.floor(value * scale + 0.5) / scale)
end

local function bench(name, perCallBytes, op)
	local rates = {}
	for r = 1, ROUNDS do
		local ms = round(op)
		rates[r] = perCallBytes > 0 and perCallBytes / ms / 1000.0 or ms * 1000.0
	end
	table.sort(rates)
	local median = rates[2]
	local spread = (rates[3] - rates[1]) / median * 100.0
	local unit = perCallBytes > 0 and "MB/s" or "us/op"
	print(string.format("%-28s%-18s%s", name, fixed(median, 3) .. " " .. unit, "spread " .. fixed(spread, 1) .. "%"))
end

local sink = 0

local function fib(n)
	if n < 2 then return n end
	return fib(n - 1) + fib(n - 2)
end

local function inc(x)
	return x + 1
end

local function makeScale(k)
	return function(x) return x * k end
end

local scale = makeScale(3)
local point = { x = 0, y = 0 }
local origin = { x = 1, y = 2 }
local counter = 1
local sqrt = math.sqrt

local ints = {}
for i = 0, 999 do ints[i + 1] = i end

local tbl = {}
for i = 0, 999 do tbl[i * 7919] = i end

bench("int add loop 1k", 0, function()
	local s = 0
	for i = 0, 999 do s = s + i end
	sink = sink + s
end)
bench("float add loop 1k", 0, function()
	local acc = 0.0
	for _ = 0, 999 do acc = acc + 1.5 end
	sink = sink + acc
end)
bench("int to float 1k", 0, function()
	local acc = 0.0
	for i = 0, 999 do acc = acc + i end
	sink = sink + acc
end)
bench("fib(25) recursion", 0, function() sink = sink + fib(25) end)
bench("module variable read 1k", 0, function()
	local s = 0
	for _ = 0, 999 do s = s + counter end
	sink = sink + s
end)
bench("module object read 1k", 0, function()
	local s = 0
	for _ = 0, 999 do s = s + origin.x end
	sink = sink + s
end)
bench("field read/write 1k", 0, function()
	local p = point
	p.x = 0
	p.y = 0
	for _ = 0, 999 do
		p.x = p.x + p.y
		p.y = p.y + 1
	end
	sink = sink + p.x
end)
bench("ms call 1k", 0, function()
	local s = 0
	for i = 0, 999 do s = s + inc(i) end
	sink = sink + s
end)
bench("closure call 1k", 0, function()
	local f = scale
	local s = 0
	for i = 0, 999 do s = s + f(i) end
	sink = sink + s
end)
bench("Math.sqrt host call 1k", 0, function()
	local acc = 0.0
	for _ = 0, 999 do acc = sqrt(acc + 2.0) end
	sink = sink + acc
end)
bench("array push 1k", 0, function()
	local out = {}
	for i = 0, 999 do out[i + 1] = i end
	sink = sink + #out
end)
bench("array index 1k", 0, function()
	local a = ints
	local s = 0
	for i = 1, 1000 do s = s + a[i] end
	sink = sink + s
end)
bench("string concat 1k", 0, function()
	local out = ""
	for _ = 0, 999 do out = out .. "ab" end
	sink = sink + #out
end)
bench("Map set 1k", 0, function()
	local m = tbl
	for i = 0, 999 do m[i * 7919] = i end
end)
bench("Map get 1k", 0, function()
	local m = tbl
	local s = 0
	for i = 0, 999 do
		local v = m[i * 7919]
		if v ~= nil then s = s + v end
	end
	sink = sink + s
end)
bench("object alloc 1k", 0, function()
	local s = 0
	for i = 0, 999 do
		local p = { x = i, y = i }
		s = s + p.x
	end
	sink = sink + s
end)

if sink < 0 then print("unreachable", sink) end
