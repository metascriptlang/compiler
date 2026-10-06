// @maxrss: 30
// @stdout: nrvo-overload acc=102
// note: Locks NRVO for OVERLOADED struct-returning operators across every value position (return/arg/array/ternary). The TAG_CALL_OVERLOAD codegen path (emitCallExpr) emitted f(args) by-value instead of f(&tmp, args), so an overloaded operator returning a struct miscompiled (C 'too few arguments') everywhere except variable-decl (which pre-handles NRVO itself). Marker proves correct VALUES at runtime — a regression re-breaks the build or the math. Reference (Nim) has no such bug: overloads resolve in sem → one genCall path → isInvalidReturnType handled uniformly.

// Regression: an OVERLOADED struct-returning operator must use the NRVO out-param
// convention in EVERY value position (return / arg / array / ternary), same as a
// non-overloaded call. Before the fix the TAG_CALL_OVERLOAD codegen path emitted
// `f(args)` by-value instead of `f(&tmp, args)` → C "too few arguments" / miscompile.

struct V { x: float32; y: float32; }

function `*`(this a: V, b: V): V { return { x: a.x * b.x, y: a.y * b.y }; }
function `*`(this a: V, b: float32): V { return { x: a.x * b, y: a.y * b }; }

function mkV(x: float32, y: float32): V { return { x: x, y: y }; }
function sumV(v: V): float32 { return v.x + v.y; }
function inReturn(a: V, b: V): V { return a * b; }

function main(): void {
	const a = mkV(2.0, 3.0);
	const b = mkV(4.0, 5.0);

	const r = inReturn(a, b);                       // return position → (8,15)
	const s1: float32 = sumV(a * b);                // arg position    → 23
	const arr: V[] = [a * b, a * 2.0];              // array position  → (8,15),(4,6)
	const s2: float32 = sumV(arr[0]) + sumV(arr[1]); //               → 23 + 10 = 33
	const t: V = (a.x < b.x) ? a * b : a;           // ternary position → (8,15)
	const s3: float32 = sumV(t);                    //                 → 23

	const acc: int32 = (sumV(r) + s1 + s2 + s3) as int32;  // 23+23+33+23 = 102
	console.log(`nrvo-overload acc=${acc}`);
}

main();
