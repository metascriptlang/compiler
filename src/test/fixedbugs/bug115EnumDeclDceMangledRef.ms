// bug115 - DCE swept an enum declaration while its checker-mangled member
//           references survived, so the JS bundle referenced undefined names
//
// Symptom:    `enum Color { Red, Green, Blue }` + any use of `Color.Red` built
//             fine on C (member values are inlined) but the JS lane died at
//             runtime: `ReferenceError: Color_Red is not defined`. Surfaced by
//             the 2026-09-01 js audit on corpus 624/700 (and every program
//             whose enum uses all fold away on the C side).
// Root cause: checkMemberExpr rewrites `Color.Red` to the identifier
//             `Color_Red` (callResolve enum-member rewrite), so the DCE
//             mark-sweep never saw a reference to the name `Color` and swept
//             the EnumDecl. The C emitter inlines member values and never
//             needed the decl; the JS emitter emits the flat
//             `var Color_Red = 0;` constants and did.
// Fix:        sweepDeadDecls seeds an enum alive when any of its member
//             mangles (`Color_Red`, ...) appears in the reference set
//             (src/transform/analysis/dce.ms).

import { compileToJS } from "../helpers";

test "bug115: enum decl survives when only mangled member refs remain" {
	const js = compileToJS("enum Color { Red, Green, Blue }\nconst ei: int32[] = [];\nei.push(Color.Red);\nei.push(Color.Blue);\nconst n = ei.length;");
	assert js.ok;
	assert js.value.contains("var Color_Red = 0;");
	assert js.value.contains("var Color_Blue = 2;");
}

test "bug115: an enum with zero references is still swept" {
	const js = compileToJS("enum Unused { A, B }\nconst x = 1;");
	assert js.ok;
	assert !js.value.contains("var Unused_A");
}
