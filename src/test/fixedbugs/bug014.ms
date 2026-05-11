// bug014 — mutual / multi-step cyclic inheritance produced misleading errors
//
// Symptom:    `class A extends B; class B extends A` (and longer chains
//             like A→C→B→A) compiled with a confusing diagnostic about
//             a redefined inherited field instead of a cyclic-inheritance
//             error. The direct self-cycle case (`class A extends A`)
//             already reported gracefully.
//
// Root cause: The cycle check in `resolveClass` (src/checker/resolvePass.ms)
//             only detected the direct self-cycle (`bareParentName ===
//             d.className`). For multi-step cycles it relied on the
//             `Shaping`-state guard inside `ensureShaped`, but
//             `resolveClass` flips the symbol to `Shaped` early to
//             support forward references inside method bodies — by the
//             time recursive resolution reaches the original class, the
//             state guard misses. Partial fields end up merged either
//             way and the downstream "field 'x' redefines inherited
//             field" diagnostic surfaced from the resulting messy state.
//
// Fix:        Walk the parent chain *structurally* via the `classExtends`
//             annotation strings before triggering parent resolution. If
//             the chain leads back to the class being resolved, report
//             "cyclic inheritance" the same way the direct-self-cycle
//             branch does and bail. Bounded to 64 steps as a defensive
//             cap. Detection is now independent of the state machine.

import { compileToC } from "../helpers";

test "bug014: mutual cycle (A extends B, B extends A) errors gracefully" {
	const src = `
class A extends B { x: int32; }
class B extends A { y: int32; }
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("cyclic inheritance");
	}
}

test "bug014: 3-level cycle (A→C, B→A, C→B) errors gracefully" {
	const src = `
class A extends C { x: int32; }
class B extends A { y: int32; }
class C extends B { z: int32; }
`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("cyclic inheritance");
	}
}

test "bug014: direct self-cycle still detected (regression guard)" {
	const src = `class A extends A { x: int32; }`;
	const c = compileToC(src);
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("cyclic inheritance");
	}
}

test "bug014: linear inheritance (no cycle) still compiles" {
	const src = `
class A1 { x: int32; constructor(x: int32) { this.x = x; } }
class B1 extends A1 { y: int32; constructor(x: int32, y: int32) { super(x); this.y = y; } }
class C1 extends B1 { z: int32; constructor(x: int32, y: int32, z: int32) { super(x, y); this.z = z; } }

function main(): void {
	const c = new C1(1, 2, 3);
	const _x = c.x;
}
`;
	const c = compileToC(src);
	assert c.ok;
}
