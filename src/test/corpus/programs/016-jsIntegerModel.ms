// @xfail(js): the JS backend has no integer model — integer division emits a
//   bare `/` (7 / 2 is 3.5) and `as int32` is a no-op (3.9 stays 3.9), so most
//   checks below read a fraction. Full measured matrix and the phase plan are in
//   docs/JS-NUMERIC.md; this program IS that document's acceptance gate, so the
//   XPASS it will eventually report is the signal that a phase landed.
// @stdout: js-integer-model all-ok
// Oracle program — integer arithmetic must mean the same thing on every backend.
// C is the specification: `/` on two integer-typed operands truncates toward
// zero, unsigned types wrap, and a float assigned into an integer slot is
// truncated at the boundary.
//
// Only cases where C produces a VALUE are in here. Signed overflow, `1 << 31`,
// `INT32_MIN / -1`, division by zero and out-of-range conversion all TRAP on a
// debug C build (measured), so there is no number for another backend to match
// and they cannot live in a self-grading program — they belong to the guard
// tier. docs/JS-NUMERIC.md §2 records what each of them does.
//
// Every input goes through an opaque() so constant folding cannot answer a check
// before codegen ever runs — folded, `7 / 2` is computed by the compiler's own
// arithmetic and proves nothing about emission.

// Exit code rides main's return rather than std/process.exit: `@import` with a
// renaming binding (`platform as _nodePlatform`) does not parse, which takes the
// whole std/process module down on the JS backend and would turn this program's
// js cell into a parse error instead of the arithmetic signal it exists to give.

let failures: int32 = 0;

function opaqueI32(v: int32): int32 { return v; }
function opaqueU32(v: uint32): uint32 { return v; }
function opaqueF64(v: float64): float64 { return v; }

function check(label: string, ok: boolean): void {
	if (!ok) failures = failures + 1;
	console.log(label + "=" + (ok ? "ok" : "BAD"));
}

// The four implicit float -> int paths the checker accepts. Each is a separate
// conversion site in the pipeline, so each is probed separately.
function takesI32(n: int32): int32 { return n; }

function returnsI32(): int32 {
	const f: float64 = opaqueF64(3.9);
	return f;
}

function main(): number {
	// --- integer division truncates toward zero (NOT toward -infinity) ---
	check("divPos", opaqueI32(7) / opaqueI32(2) === 3);
	check("divNeg", opaqueI32(0 - 7) / opaqueI32(2) === -3);
	check("divExact", opaqueI32(8) / opaqueI32(2) === 4);
	check("divSmaller", opaqueI32(1) / opaqueI32(2) === 0);

	// --- remainder keeps the dividend's sign, as in C ---
	check("modPos", opaqueI32(7) % opaqueI32(2) === 1);
	check("modNeg", opaqueI32(0 - 7) % opaqueI32(2) === -1);

	// --- the digit loop: the shape that made this bug visible in the first
	// place. With a fractional quotient the value decays through denormals
	// instead of reaching 0, so the iteration count explodes. Capped so a
	// regression cannot hang the gate.
	let n: int32 = opaqueI32(1000);
	let iters: int32 = 0;
	while (n !== 0 && iters < 100) {
		n = n / 10;
		iters = iters + 1;
	}
	check("divLoopIters", iters === 4);

	// --- unsigned division and wrap ---
	check("udiv", opaqueU32(7) / opaqueU32(2) === 3);
	const uwrapExpect: uint32 = 4294967295;
	check("uwrap", opaqueU32(0) - opaqueU32(1) === uwrapExpect);

	// --- explicit conversion truncates toward zero at every width ---
	check("convI32", (opaqueF64(3.9) as int32) === 3);
	check("convI32Neg", (opaqueF64(0.0 - 3.9) as int32) === -3);
	check("convI16", (opaqueF64(3.9) as int16) === 3);
	check("convI8", (opaqueF64(3.9) as int8) === 3);
	check("convU8", (opaqueF64(3.9) as uint8) === 3);
	check("convU32", (opaqueF64(3.9) as uint32) === 3);

	// --- the four implicit paths, which carry no `as` at all ---
	const viaDecl: int32 = opaqueF64(3.9);
	check("convViaDecl", viaDecl === 3);

	check("convViaParam", takesI32(opaqueF64(3.9)) === 3);

	check("convViaReturn", returnsI32() === 3);

	let viaAssign: int32 = 0;
	viaAssign = opaqueF64(3.9);
	check("convViaAssign", viaAssign === 3);

	if (failures === 0) {
		console.log("js-integer-model all-ok");
		return 0;
	}
	console.log("js-integer-model failures=" + failures.toString());
	return 1;
}
