// Checker — a subscript of a type without a builtin one is a call of its declared `[]` / `[]=`

import { strictErrorCount, hasError } from "./helpers";

const P = "struct P { v: int32; }\nlet z: P = { v: 100 };\n";
const GET = "function `[]`(this self: P, i: int32): int32 { return i + self.v; }\n";
const SET = "function `[]=`(this ref self: P, i: int32, x: int32): void { self.v = i + x; }\n";
const NO_SET = "returns a value, so this subscript cannot be assigned to";

test "a declared [] types the subscript with the routine's result" {
	assert strictErrorCount(P + GET + "const w: int32 = z[3];") == 0;
	assert hasError(P + GET + "const s: string = z[1];", "Type 'int32' is not assignable to type 'string'");
	assert hasError(P + GET + "const t: int32 = z[\"a\"];", "'[]'");
}

test "a struct or a number without [] cannot be indexed" {
	assert hasError(P + "const w = z[3];", "type 'P' has no '[]' operator");
	assert hasError("const n: int32 = 4;\nconst d = n[0];", "has no '[]' operator");
	assert hasError(P + SET + "const w = z[3];", "type 'P' has no '[]' operator");
}

test "only x[i] = v writes through a subscript, and only with a declared []=" {
	assert strictErrorCount(P + GET + SET + "z[3] = 4;") == 0;
	assert hasError(P + GET + "z[3] = 4;", NO_SET);
	assert hasError(P + GET + SET + "z[3] += 1;", NO_SET);
	assert hasError("struct Q { v: int32; }\n" + P + "function `[]`(this self: P, i: int32): Q { return { v: i }; }\nz[3].v = 1;", NO_SET);
}

test "a []= with a ref receiver needs a writable location" {
	assert hasError("struct P { v: int32; }\nconst z: P = { v: 100 };\n" + SET + "z[3] = 4;", "const");
}
