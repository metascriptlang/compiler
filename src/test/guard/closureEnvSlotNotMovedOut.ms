// nim-guard: a captured variable lives in the closure environment, and the
// environment is shared with every closure created from it — so the enclosing
// function never moves a captured slot out, even at its own textual last read.
//
// INVARIANT (reference lambda lifting + injectdestructors):
//   - the enclosing function reaches a captured variable through the env
//     variable by DEREF + field access (the indirect-access builder), never as
//     a plain field path rooted at the env variable.
//   - the move analysis refuses any path that crosses a ref deref ("we own
//     sinkparam[].loc but not ourVar[].location"): the env is a ref, other
//     holders (the closures) can still read the slot, so a last read of
//     `env[].x` is a COPY, not a destructive move.
//   - the env VARIABLE itself is an ordinary owned local: its last read (the
//     closure pair that takes it) may sink it.
//   NIM-REF TR-20 — SAME.
//
// WHAT IT CATCHES:
//   - the outer-scope rewrite emitting `env.x` without the hidden deref once the
//     env variable carries a symbol: the analyzer then sees an analysable field
//     access, moves `x` out of the env at the outer last read and nulls the
//     slot; the next closure call reads null (crash) or a stale owner
//     (double destroy).
//
// RED MEANS: a captured slot was moved out of a live env. The failing shape is
//   printed (H<Shape>). Run /trace-nim on rewriteOuterRef / envVarDeref in
//   transform/lowering/lambdaLifting.ms and isAnalysableFieldAccess in
//   analyzer/alias.ms.
//
// GUARD-BALANCE HToGlobal
// GUARD-BALANCE HToArray
// GUARD-BALANCE HToLocal
// GUARD-BALANCE HToField
// GUARD-BALANCE HToReturn
// GUARD-BALANCE HToArg
// GUARD-BALANCE HInLoop
// GUARD-BALANCE HNestedDecl

let failures: int32 = 0;
function expect(shape: string, got: int32, want: int32): void {
	if (got != want) {
		failures = failures + 1;
		console.log("FAIL " + shape + " got=" + got + " want=" + want);
	}
}

class HToGlobal { n: int32; constructor() { this.n = 1; } }
let gSlot: HToGlobal | null = null;
function shapeToGlobal(): void {
	const h = new HToGlobal();
	const f = (): int32 => h.n + 10;
	gSlot = h;
	expect("HToGlobal", f(), 11);
}

class HToArray { n: int32; constructor() { this.n = 2; } }
const keep: HToArray[] = [];
function shapeToArray(): void {
	const h = new HToArray();
	const f = (): int32 => h.n + 10;
	keep.push(h);
	expect("HToArray", f(), 12);
}

class HToLocal { n: int32; constructor() { this.n = 3; } }
function shapeToLocal(): void {
	const h = new HToLocal();
	const f = (): int32 => h.n + 10;
	const other = h;
	expect("HToLocal", f() + other.n, 16);
}

class HToField { n: int32; constructor() { this.n = 4; } }
class Holder { slot: HToField | null; constructor() { this.slot = null; } }
function shapeToField(): void {
	const h = new HToField();
	const box = new Holder();
	const f = (): int32 => h.n + 10;
	box.slot = h;
	expect("HToField", f(), 14);
}

class HToReturn { n: int32; constructor() { this.n = 5; } }
let lateReturn: () => int32 = (): int32 => 0;
function shapeToReturn(): HToReturn {
	const h = new HToReturn();
	lateReturn = (): int32 => h.n + 10;
	return h;
}

class HToArg { n: int32; constructor() { this.n = 6; } }
function consume(h: HToArg): int32 { return h.n; }
function shapeToArg(): void {
	const h = new HToArg();
	const f = (): int32 => h.n + 10;
	const c = consume(h);
	expect("HToArg", f() + c, 22);
}

class HInLoop { n: int32; constructor() { this.n = 7; } }
const keepLoop: HInLoop[] = [];
function shapeInLoop(): void {
	const fs: (() => int32)[] = [];
	for (let i: int32 = 0; i < 3; i += 1) {
		const h = new HInLoop();
		fs.push((): int32 => h.n + i);
		keepLoop.push(h);
	}
	let t: int32 = 0;
	for (const f of fs) t = t + f();
	expect("HInLoop", t, 24);
}

class HNestedDecl { n: int32; constructor() { this.n = 8; } }
let gNested: HNestedDecl | null = null;
function shapeNestedDecl(): void {
	const h = new HNestedDecl();
	function read(): int32 { return h.n + 10; }
	gNested = h;
	let t: int32 = 0;
	for (let i: int32 = 0; i < 2; i += 1) t = t + read();
	expect("HNestedDecl", t, 36);
}

function main(): int32 {
	for (let round: int32 = 0; round < 50; round += 1) {
		shapeToGlobal();
		shapeToArray();
		shapeToLocal();
		shapeToField();
		const r = shapeToReturn();
		expect("HToReturn", lateReturn() + r.n, 20);
		shapeToArg();
		shapeInLoop();
		shapeNestedDecl();
	}
	gSlot = null;
	gNested = null;
	keep.length = 0;
	keepLoop.length = 0;
	lateReturn = (): int32 => 0;
	if (failures == 0) console.log("GUARD-OK");
	return failures == 0 ? 0 : 1;
}
const rc = main();
if (rc !== 0) process.exit(rc);
