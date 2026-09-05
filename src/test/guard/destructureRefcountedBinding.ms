// nim-guard: a scope's variable declarations are emitted independently of needsTry
//
// INVARIANT (Nim): processScope (injectdestructors.nim:587) appends the scope's
//   nkVarSection FIRST and unconditionally; only afterwards does needsTry choose
//   between `newTryFinally(ret, fin)` and `ret; fin`. Declaration placement and
//   cleanup placement are two independent decisions. Nim's cgen reinforces it:
//   assignLocalVar (cgen.nim:779) always declares a local into p.s(cpsLocals),
//   so no synthetic block can ever capture a declaration.
//
// WHAT IT CATCHES: genCopy emits `Block[decl, wasMoved, copy]` for a refcounted
//   binding, so the declaration starts life inside a synthetic block. MS used to
//   hoist it out only inside wrapWithTryFinally — reached solely when
//   scope.needsTry. In a scope that needs no try, the declaration stayed trapped
//   in that block while the uses and the scope-end destroy were emitted in the
//   enclosing scope, and clang rejected the C with "use of undeclared
//   identifier". Non-refcounted bindings never enter genCopy's block, which is
//   why every pre-existing destructure guard (ints only) stayed green.
//
// RED MEANS: declaration hoisting got re-coupled to needsTry, or genCopy's block
//   stopped being unwrapped. Pre-fix this file does not COMPILE on the C backend
//   (12 "use of undeclared identifier" errors) — the failed build IS the red
//   signal. Shapes matter: a binding consumed directly by `return` lands in a
//   needsTry scope and compiles even pre-fix, so every cell below consumes its
//   binding in a plain statement.
//
// NOT covered here on purpose: destructuring DEFAULTS (`const { s = "md" } = p`).
//   They are silently unimplemented in destructuringLower — a separate invariant
//   with its own red signal (array form throws index-out-of-bounds).
//
// No RC balance directive — the signal is build failure / wrong-value throw.

interface Rec { a: string; n: int32; }
interface Opt { s?: string | null; n: int32; }
interface Wide { a: string; b: string; n: int32; }

let sink: string = "";

function objString(): void {
	const p: Rec = { a: "x", n: 2 };
	const { a, n } = p;
	console.log("cell objString a=" + a + " n=" + n.toString());
	sink = sink + a + n.toString();
}

function objMaybe(): void {
	const p: Opt = { s: null, n: 3 };
	const { s, n } = p;
	const shown = s == null ? "nil" : (s as string);
	console.log("cell objMaybe s=" + shown + " n=" + n.toString());
	sink = sink + shown + n.toString();
}

function objMaybeSet(): void {
	const p: Opt = { s: "j", n: 6 };
	const { s, n } = p;
	const shown = s == null ? "nil" : (s as string);
	console.log("cell objMaybeSet s=" + shown + " n=" + n.toString());
	sink = sink + shown + n.toString();
}

function arrString(): void {
	const src: string[] = ["p", "q"];
	const [w1, w2] = src;
	console.log("cell arrString w1=" + w1 + " w2=" + w2);
	sink = sink + w1 + w2;
}

function objRest(): void {
	const p: Wide = { a: "r", b: "s", n: 4 };
	const { a, ...rest } = p;
	console.log("cell objRest a=" + a + " restB=" + rest.b);
	sink = sink + a + rest.b;
}

function main(): void {
	objString();
	objMaybe();
	objMaybeSet();
	arrString();
	objRest();

	const expected = "x2nil3j6pqrs";
	if (sink != expected) {
		console.log("observed sink=" + sink);
		console.log("expected sink=" + expected);
		throw "GUARD RED: refcounted destructuring binding lost its value";
	}

	console.log("destructureRefcountedBinding ok");
}

main();
