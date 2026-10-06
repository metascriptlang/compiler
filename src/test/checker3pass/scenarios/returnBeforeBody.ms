import { checkOnly } from "../helpers";

const SRC_FUNCTION_CYCLE = `
function a(n: number) { if (n > 0) return b(n - 1); return 3; }
function b(n: number) { return a(n); }
const r = a(2);
`;

const SRC_LONGER_CYCLE = `
function a() { return b() + 1; }
function b() { return c() + 1; }
function c() { const x = a(); return x; }
const r = a();
`;

const SRC_METHOD_CYCLE = `
class P {
	ping(n: number) { return n > 0 ? this.pong(n - 1) : 0; }
	pong(n: number) { return this.ping(n) + 1; }
}
const r = new P().ping(3);
`;

const SRC_DISCARDED_CYCLE = `
let count = 0;
function render() { count += 1; if (count < 3) update(); return count * 2; }
function update() { render(); }
async function load() { await save(); return 1; }
async function save() { await load(); }
const r = render();
`;

const SRC_SELF = `
function f(n: number) { if (n == 0) return 0; return f(n - 1) + 1; }
const r = f(3);
`;

test "a routine whose inferred return is read back through another unannotated routine is refused, naming the cycle" {
	const text = checkOnly(SRC_FUNCTION_CYCLE).errors.join("\n");
	assert text.contains("cannot infer the return type of 'a': 'b' reads it while 'a' is still being checked (a -> b -> a)"), "a -> b -> a must be refused: " + text;
}

test "a cycle through two routines names both" {
	const text = checkOnly(SRC_LONGER_CYCLE).errors.join("\n");
	assert text.contains("cannot infer the return type of 'a': 'b', 'c' read it while 'a' is still being checked (a -> b -> c -> a)"), "a -> b -> c -> a must be refused: " + text;
}

test "a method cycle through this is refused with the class-qualified names" {
	const text = checkOnly(SRC_METHOD_CYCLE).errors.join("\n");
	assert text.contains("cannot infer the return type of 'P.ping': 'P.pong' reads it while 'P.ping' is still being checked (P.ping -> P.pong -> P.ping)"), "P.ping -> P.pong -> P.ping must be refused: " + text;
}

test "a cycle that only discards the result checks" {
	const result = checkOnly(SRC_DISCARDED_CYCLE);
	assert result.errors.length == 0, "a discarded call back into a routine being checked must check: " + result.errors.join("\n");
}

test "direct self recursion infers its return" {
	const result = checkOnly(SRC_SELF);
	assert result.errors.length == 0, "self recursion must check: " + result.errors.join("\n");
}
