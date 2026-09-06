// nim-guard: destructuring pattern bindings carry real element/field types
//
// INVARIANT (Nim): a destructuring binding is typed by the SAME path as the
//   generated access — Nim has no separate "pattern binding typing" at all:
//   makeVarTupleSection rewrites `var a, b = unpack` into N plain defs whose
//   RHS is `tmp[j]` and re-sems them (semstmts.nim:757 `semVarOrLet` recursion),
//   so a binding's type can never diverge from `src[j]`'s type. MS keeps two
//   readers of ONE derivation: checker `defineForOfPatternBindings` and
//   transform `destructuringLower.destrElemType` both call
//   `destrPositionalElemType`/`destrNamedFieldType` (checker/types.ms).
//   Before the fix the checker had its own partial copy (Tuple-only) and never
//   stamped pattern identifiers' `nodeType`.
//
// WHAT IT CATCHES: the silent-wrong-value family — with untyped bindings,
//   `.toString()` folds to the literal "<object>" (builtinLower fallback) and
//   prints wrong on BOTH backends; object-pattern bindings emitted as `void*`
//   failed the C compile; closure captures of destructured elems typed the
//   lifted env field as double/void*.
//
// RED MEANS: the checker (or transform) regrew a private element-type
//   derivation that misses Array element / Struct field / per-index Tuple, or
//   stopped stamping pattern identifiers' nodeType. Run /trace-nim on
//   defineForOfPatternBindings vs makeVarTupleSection (semstmts.nim).
//   Proven RED on the pre-fix binary (v0.2.53: C compile fails at the
//   object-pattern `void *` decl — the loudest symptom of the untyped binding);
//   GREEN post-fix.
//
// No RC balance directive — the signal is wrong-value-throw / build failure.

const src: int32[] = [3, 4];
const [a, b] = src;

interface P { x: int32; y: int32; }
const p: P = { x: 3, y: 4 };
const { x, y } = p;

const t: [int32, int32] = [5, 6];
const [u, v] = t;

const words: string[] = ["x", "y"];
const [w1, w2] = words;

function main(): void {
	// (1) array element type — the original silent "<object>" symptom
	if (a + b != 7) { throw "GUARD RED: array elem value wrong"; }
	if (a.toString() != "3") { throw "GUARD RED: array elem toString folded to <object> (untyped binding)"; }

	// (2) object-pattern field type — was void* + clang error
	if (x + y != 7) { throw "GUARD RED: object field value wrong"; }
	if (y.toString() != "4") { throw "GUARD RED: object field toString folded to <object>"; }

	// (3) tuple source stays per-index typed
	if (u + v != 11) { throw "GUARD RED: tuple elem value wrong"; }

	// (4) string elems concat as strings, not <object>
	if (w1 + w2 != "xy") { throw "GUARD RED: string elem concat wrong"; }

	// (5) destructured elem captured into a lifted closure — env field must be typed
	const g = (): int32 => { const [c, d] = src; return c + d; };
	if (g() != 7) { throw "GUARD RED: closure capture of destructured elem untyped"; }

	// (6) for-of destructured binding keeps the element type
	const rows: int32[][] = [[10, 20]];
	for (const [r0, r1] of rows) {
		if (r0 + r1 != 30) { throw "GUARD RED: for-of destructured elem value wrong"; }
		if (r0.toString() != "10") { throw "GUARD RED: for-of destructured toString folded"; }
	}

	console.log("destructureBindingTypes ok");
}

main();
