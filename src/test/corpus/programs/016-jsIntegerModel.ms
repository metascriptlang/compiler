// @stdout: js-integer-model all-ok
// This program is the acceptance gate for docs/JS-NUMERIC.md. It was marked
// known-fail on the js lane until the conversion, division and uint32 phases
// landed; adding a case for a phase that has NOT landed means marking that lane
// again, not weakening the check. Keep a directive name out of column one in
// this header — the runner reads any leading comment line that starts with one
// as a real directive, prose or not.
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

// Graded by @stdout rather than by exit code: std/process cannot be imported
// here because `@import` with a renaming binding (`platform as _nodePlatform`)
// does not parse, which would turn this program's js cell into a parse error
// instead of the arithmetic signal it exists to give.

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
	check("uaddWrap", opaqueU32(4294967295) + opaqueU32(1) === 0);

	// --- unsigned bitwise: every JS bitwise operator yields an int32, so any
	// result with the high bit set reads back negative unless it goes through
	// ToUint32. `&` is included even though it cannot overflow: the operand
	// values already exceed int32, so the RESULT representation is what breaks.
	const uHighBit: uint32 = 2147483648;
	const uorExpect: uint32 = 2147483649;
	const uxorExpect: uint32 = 4294967294;
	check("uand", (opaqueU32(4294967295) & opaqueU32(4294967295)) === uwrapExpect);
	check("uor", (opaqueU32(2147483648) | opaqueU32(1)) === uorExpect);
	check("uxor", (opaqueU32(4294967295) ^ opaqueU32(1)) === uxorExpect);
	check("unot", (~opaqueU32(0)) === uwrapExpect);
	check("ushl", (opaqueU32(1) << opaqueU32(31)) === uHighBit);

	// The one case a trailing ToUint32 cannot repair: JS shifts the int32 view
	// arithmetically, so 0x80000000 >> 1 keeps the sign and masking afterwards
	// yields 0xC0000000. The operator itself has to become `>>>`.
	check("ushr", (opaqueU32(2147483648) >> opaqueU32(1)) === 1073741824);

	// Both products exceed 2^53, where a double multiply has already lost the
	// low bits before any mask can run — these are what force an exact 32-bit
	// multiply rather than `(a * b) >>> 0`.
	const umulOddExpect: uint32 = 3906153237;
	check("umulMax", opaqueU32(4294967295) * opaqueU32(4294967295) === 1);
	check("umulOdd", opaqueU32(3000000007) * opaqueU32(700000003) === umulOddExpect);

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

main();
