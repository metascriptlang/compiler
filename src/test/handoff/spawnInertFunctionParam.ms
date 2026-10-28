import { hasError, strictErrorCount } from "./helpers";

const SHAPES = `
class Slot { fn: () => int32; constructor(fn: () => int32) { this.fn = fn; } }
class Bag {
	slot: Slot | null = null;
	drop(listener: () => int32): void {
		if (this.slot != null && this.slot!.fn === listener) this.slot = null;
	}
}
function dropFree(f: () => int32, g: () => int32): boolean { return f === g; }
function callIt(f: () => int32): int32 { return f(); }
function compareThenCall(f: () => int32, g: () => int32): int32 { if (f === g) return 0; return f(); }
function pick(): () => int32 { return (): int32 => 1; }
`;

test "spawnInertFunctionParam: a callee that only compares a function value runs nothing" {
	const method = SHAPES + "async function g(): Promise<int32> { const h = pick(); return await spawn(() => { const b = new Bag(); b.drop(h); return 0; }); }";
	assert strictErrorCount(method) == 0, "a method comparing the parameter";
	const free = SHAPES + "async function g(): Promise<boolean> { const h = pick(); return await spawn(() => dropFree(h, h)); }";
	assert strictErrorCount(free) == 0, "a function comparing the parameter";
}

test "spawnInertFunctionParam: a callee that calls the value, or compares and calls it, stays refused" {
	const called = SHAPES + "async function g(): Promise<int32> { const h = pick(); return await spawn(() => callIt(h)); }";
	assert hasError(called, "passes a function value") && strictErrorCount(called) > 0, "called";
	const both = SHAPES + "async function g(): Promise<int32> { const h = pick(); return await spawn(() => compareThenCall(h, h)); }";
	assert hasError(both, "passes a function value") && strictErrorCount(both) > 0, "compared then called";
}
