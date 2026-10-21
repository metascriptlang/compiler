// nim-guard: local functions that call each other share their frame's env without the env
// holding a closure of one of them, so the env is freed when its last closure goes.
//
// Nim: lambdalifting.nim liftCapturedVars (nkSym of an inner proc) lifts the callee once and
// symToClosure builds `(callee, env)` at every use, whatever the declaration order; an inner proc
// is never a captured variable, so no env field points back at its own env. The detection pass
// decides each inner proc's env before any use is lifted (detectCapturedVars, markAsClosure).
//
// counterA / counterB call a sibling declared after them and return either end; cycle runs
// three locals in a ring; deeper nests the pair one function down; inLoop has the earlier
// local reach the later one's per-iteration env through a mutual call; walk keeps the pair in
// a generator.
//
// RED MEANS a local function called before its declaration is stored in the env it captures
// (`env.b = { lifted_b, env }`), a self-cycle --gc=drc never frees: run /trace-nim on the
// routine pre-decision in lambda lifting (promiseRun / routineEnv).
//
// GUARD-BALANCE dollarEnv_counterA_shared_
// GUARD-BALANCE dollarEnv_counterB_shared_
// GUARD-BALANCE dollarEnv_cycle_shared_
// GUARD-BALANCE dollarEnv_deeper_shared_
// GUARD-BALANCE dollarEnv_inLoop_shared_
// GUARD-BALANCE dollarEnv_walk_shared_
// GUARD-JS

function counterA(): () => int32 {
	let n: int32 = 0;
	function a(): int32 { n += 1; return n < 3 ? b() : n; }
	function b(): int32 { return a(); }
	return a;
}

function counterB(): () => int32 {
	let n: int32 = 0;
	function a(): int32 { n += 1; return n < 3 ? b() : n; }
	function b(): int32 { return a(); }
	return b;
}

function cycle(): () => string {
	let out = "";
	let n: int32 = 0;
	function x(): string { out += "x"; n += 1; return n < 4 ? y() : out; }
	function y(): string { out += "y"; return z(); }
	function z(): string { out += "z"; return x(); }
	return y;
}

function deeper(): () => int32 {
	let k: int32 = 1;
	function outer(): int32 {
		function f(): int32 { k += 1; return k < 4 ? g() : k; }
		function g(): int32 { return f(); }
		return f();
	}
	return outer;
}

function inLoop(): int32 {
	const fs: Array<() => int32> = [];
	let base: int32 = 10;
	for (let i: int32 = 0; i < 3; i++) {
		function a(): int32 { return base + (base < 0 ? b() : 0); }
		function b(): int32 { return i + (i < 0 ? a() : 0); }
		fs.push(a);
		fs.push(b);
	}
	let s: int32 = 0;
	for (const f of fs) s = s + f();
	return s;
}

function* walk(limit: int32): Iterator<int32> {
	let n: int32 = 0;
	function a(): int32 { n += 1; return n % 2 == 0 ? b() : n; }
	function b(): int32 { return n * 10; }
	while (n < limit) { yield a(); }
}

function main(): void {
	let total: int32 = 0;
	let ring = "";
	for (let r: int32 = 0; r < 200; r++) {
		total = total + counterA()() + counterB()() + deeper()() + inLoop();
		ring = cycle()();
		for (const v of walk(4)) total = total + v;
	}
	console.log(`total=${total} ring=${ring}`);
	if (total != 21400) throw "GUARD RED: a local function read the wrong value, got=" + total.toString();
	if (ring != "yzxyzxyzxyzx") throw "GUARD RED: the ring of local functions ran out of order, got=" + ring;
	console.log("GUARD-OK");
}
main();
