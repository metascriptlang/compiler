// bug074 — branded primitives erased silently (`string & { __brand }` = bare string)
//
// Symptom:    cross-brand and base→brand arguments compiled clean; the TS brand
//             pattern gave zero protection (TSGAP item 5, decided 2026-08-01).
// Root cause: resolvePass intersection block erased any primitive-operand mix
//             to its first operand ("first operand wins").
// Fix:        brand pattern → one-way Distinct (TypeFlag.BrandWiden); identity
//             = brand literal pairs; erased to base post-check (brandErase.ms).

import { compileToC } from "../helpers";

type CubeId = string & { __brand: "CubeId" };
type AltCube = string & { __brand: "CubeId" };

function takeCube(id: CubeId): string { return id as string; }
function takeString(s: string): string { return s; }

test "bug074: brand widens to base implicitly" {
	const c: CubeId = "abc" as CubeId;
	assert takeString(c) == "abc";
	assert c.length == 3;
}

test "bug074: same brand literal is one type across aliases" {
	const a: AltCube = "xyz" as AltCube;
	assert takeCube(a) == "xyz";
}

test "bug074: brand equality lowers as base equality" {
	const c1: CubeId = "k" as CubeId;
	const c2: CubeId = "k" as CubeId;
	assert c1 == c2;
}

test "bug074: cross-brand argument is rejected" {
	const out = compileToC("type A = string & { __brand: \"A\" };\ntype B = string & { __brand: \"B\" };\nfunction f(a: A): string { return a as string; }\nfunction g(): string { const b: B = \"x\" as B; return f(b); }");
	assert !out.ok;
}

test "bug074: bare base into brand parameter is rejected" {
	const out = compileToC("type A = string & { __brand: \"A\" };\nfunction f(a: A): string { return a as string; }\nfunction g(): string { return f(\"raw\"); }");
	assert !out.ok;
}
