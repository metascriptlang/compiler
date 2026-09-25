// bug525 — isAssignable answered "assignable" once its recursion passed depth 20
//
// Symptom:    two function types nested 20 or more levels deep that differ only in the innermost
//             parameter (`int32` against `string`) were accepted as a call argument; 19 levels were
//             refused.
//
// Root cause: isAssignable returned true past depth 20 (typeRelation returned Generic past 20,
//             isReinterpretUnsafe returned "safe" past 12) — a cap that answered yes by default.
//
// Fix:        a pair already being related is assumed related (the coinductive rule that cuts a
//             recursive type's cycle), and only a runaway past a hard depth answers no.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

function nested525(depth: int32, same: boolean): string {
	let src = "type A0 = (x: int32) => int32;\ntype B0 = (x: " + (same ? "int32" : "string") + ") => int32;\n";
	for (let i = 1; i <= depth; i += 1) {
		src = src + "type A" + i.toString() + " = (x: A" + (i - 1).toString() + ") => int32;\n";
		src = src + "type B" + i.toString() + " = (x: B" + (i - 1).toString() + ") => int32;\n";
	}
	const top = depth.toString();
	const below = (depth - 1).toString();
	return src + "function take(f: B" + top + "): int32 { return 1; }\n"
		+ "function mk(): A" + top + " { return (x: A" + below + "): int32 => 0; }\n"
		+ "const r = take(mk());\n";
}

test "bug525: a mismatch 20 levels down is refused" {
	assert hasError(nested525(20, false), "Argument type mismatch in 'take' arg 0");
}

test "bug525: a mismatch 25 levels down is refused" {
	assert hasError(nested525(25, false), "Argument type mismatch in 'take' arg 0");
}

test "bug525: the same types 25 levels down stay assignable" {
	const r = compileToC(nested525(25, true));
	assert r.ok, r.error;
}

test "bug525: a self-referential object type still relates to itself" {
	const r = compileToC("interface L525 { next: L525 | null; v: int32; }\nfunction f(l: L525): int32 { return l.v; }\nconst a: L525 = { next: null, v: 1 };\nconst b: L525 = { next: a, v: 2 };\nconst r = f(b);\n");
	assert r.ok, r.error;
}
