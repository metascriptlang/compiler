// bug086 — indirect interface-extends cycle accepted silently
//
// Symptom:    `interface A extends B` + `interface B extends A` built AND ran;
//             field visibility depended on resolution order (the probe happened
//             to merge both fields). Only the direct self-cycle
//             (`A extends A`) was detected. TS errors on every interface in
//             the cycle.
// Root cause: resolveInterface compared each parent NAME against the declaring
//             interface's own name only — no transitive walk over the extends
//             chain (Neon BUGS.md §2, filed by the B4 audit round 2).
// Fix:        interfaceCycleChain — visited-set DFS over declNode extends
//             lists before resolving each parent; any path back to the
//             declaring interface errors with the chain spelled out.

import { hasError, strictErrorCount } from "../handoff/helpers";

test "bug086: two-interface extends cycle is an error" {
	assert hasError("interface A extends B { a: number; }\ninterface B extends A { b: number; }", "cyclic");
}

test "bug086: three-interface extends cycle is an error" {
	assert hasError("interface A extends B { a: number; }\ninterface B extends C { b: number; }\ninterface C extends A { c: number; }", "cyclic");
}

test "bug086: direct self-cycle still errors" {
	assert hasError("interface A extends A { a: number; }", "cyclic");
}

test "bug086: a straight extends chain stays legal" {
	const src = "interface C { c: number; }\ninterface B extends C { b: number; }\ninterface A extends B { a: number; }\nconst x: A = { a: 1, b: 2, c: 3 };";
	assert strictErrorCount(src) == 0;
}

test "bug086: a diamond is not a false cycle" {
	// D is reached twice (via B and via C) — a revisit must not read as a cycle.
	// D stays empty so the duplicate-field rule cannot fire and mask the answer.
	const src = "interface D { }\ninterface B extends D { b: number; }\ninterface C extends D { c: number; }\ninterface A extends B, C { a: number; }";
	assert strictErrorCount(src) == 0;
}

test "bug086: a generic parent chain stays legal" {
	const src = "interface Box<T> { item: T; }\ninterface Tagged extends Box<number> { tag: string; }";
	assert strictErrorCount(src) == 0;
}
