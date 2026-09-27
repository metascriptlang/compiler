// bug331 — a POD-only named union field called hooks that were never generated
//
// Symptom:    `type N = int32 | float64` as a field beside a managed field: the
//             container's Destroy/Sink/WasMoved called NDestroy/NWasMoved, which
//             no module defines, so the C compile failed (audit lift-hooks-10).
//
// Root cause: ensureHooks recorded a type that needs no hooks as generated, so
//             namedTypeHasHooks answered yes and fillBody's Union arm called them
//             (reference: liftdestructors.nim isTrivial, defaultOp).
//
// Fix:        such a type is recorded as trivial; the Union arm takes defaultOp.

import { compileToC } from "../helpers";

test "bug331: a POD union field of a struct is blitted, not hooked" {
	const src = `
type N = int32 | float64;
struct S {
	n: N;
	s: string;
}
function run(): void {
	let a: S = { n: 5 as int32, s: "x" + "y" };
	const b: S = a;
	a = { n: 2.5, s: "z" + "w" };
	console.log(b.s + a.s);
}
run();
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("((*dest).n = (*src).n);");
		assert !c.value.contains("WasMoved(&((*self).n))");
		assert !c.value.contains("Destroy(&((*self).n))");
	}
}

test "bug331: a POD union field of a class is left to the blit" {
	const src = `
type N = int32 | float64;
class C {
	n: N = 1 as int32;
	s: string = "";
}
const c = new C();
c.s = "a" + "b";
console.log(c.s);
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert !c.value.contains("Destroy(&((*self).n))");
		assert c.value.contains("msStringDecref((*self).s);");
	}
}
