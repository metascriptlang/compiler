// bug034 — array of raw Union (discriminated union) crashed/leaked at cleanup
//
// Symptom:    Code like
//                 type V = { ok: true, value: int32 } | { ok: false, error: string };
//                 function makeVs(): V[] {
//                     const vs: V[] = [];
//                     vs.push({ ok: false, error: someAllocatedString });
//                     return vs;
//                 }
//             Compiled cleanly. At small N + literal strings: silently
//             leaked inner string refs (no decref). At large N + heap
//             strings (loop concat): panic at cleanup —
//                 thread N panic: pointer index expression with base 0x1
//                 overflowed to 0xffffffffffffffe9
//                 msHeader (drc.h:52)
//                 msDecRefIsLast (drc.h:197)
//                 msRefArrayDestroy (array.c:558)
//
// Root cause: Same family as BUG #3 (bug033). src/analyzer/classify.ms
//             classifyArray() handled `(Struct && hasAsgn)` elements but
//             NOT Union elements with the same shape. Union[] fell into
//             the unsafe default catch-all → msArrayRefDestroy was invoked
//             against a `VArray__Content` whose `data[]` was `V` structs
//             (variable size — 24B for `{ok, value | error}`), reading
//             8B as `void*` per slot → misalignment.
//
// Fix:        Three coordinated changes:
//             1. src/analyzer/classify.ms — extended `Struct && hasAsgn`
//                check to also cover `Union && hasAsgn` in classifyArray.
//             2. src/transform/lowering/destructorLifting.ms — extended
//                `scanTypeForArrays` and `arrayOp` to recognize Union
//                elements (mirrors the Struct path). This causes
//                `generateArrayHooks` to emit per-T `VArrayDestroy`
//                bodies that iterate elements and call `VDestroy` per
//                slot, properly decref'ing each variant's inner refs.
//             3. (No runtime addition needed — per-T lifting reuses
//                existing destructorLifting infrastructure for Struct.)
//
// Why per-T lift (vs runtime helper like closure): Union variant
//             destructors differ per Union type. `UDestroy` for
//             `{tag:"a"} | {tag:"b"}` decrefs different fields than
//             `VDestroy` for `{ok:true,value:int32} | {ok:false,error:string}`.
//             No uniform runtime helper possible — must generate per-T.

type Bug034Variant = { ok: true, val: int32 } | { ok: false, msg: string };

function bug034_make(n: int32): Bug034Variant[] {
	const xs: Bug034Variant[] = [];
	let i: int32 = 0 as int32;
	while (i < n) {
		// Allocate a heap string per iteration — exercises inner-ref cleanup.
		const m = "msg_" + i.toString();
		xs.push({ ok: false, msg: m });
		i = (i + (1 as int32)) as int32;
	}
	return xs;
}

test "bug034: Union[] cleanup runs cleanly under stress (no crash)" {
	let iter: int32 = 0 as int32;
	while (iter < (50 as int32)) {
		const xs = bug034_make(20 as int32);
		assert xs.length == 20;
		iter = (iter + (1 as int32)) as int32;
	}
	assert iter == 50;
}

test "bug034: Union[] inner ref decref-on-cleanup (no leak)" {
	// The cleanup must call VDestroy per element which dispatches to
	// V_v1Destroy → msStringDecref(error). If the inner string isn't
	// decref'd, this test still passes — the leak detector lives in
	// drc_array/scenarios/bug3Family.ms (asserts the analyzer routes to
	// a per-T helper, not msArrayRefDestroy).
	const xs = bug034_make(5 as int32);
	assert xs.length == 5;
	if (!xs[0].ok) assert xs[0].msg == "msg_0";
}
