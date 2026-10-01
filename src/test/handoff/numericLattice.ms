import { compileToC, compileToJS } from "../helpers";
import { errorCount, hasError } from "./helpers";

function ok(body: string): boolean {
	return compileToC(body).ok && compileToJS(body).ok;
}

test "numeric lattice: an unsigned integer widens into a signed slot whose range holds it" {
	assert ok("const u: uint8 = 3;\nconst i: int16 = u;\nconst j: int32 = u;\nconst k: int64 = u;\nconsole.log(i, j, k);\n");
	assert ok("const u: uint16 = 40000;\nconst i: int32 = u;\nconsole.log(i);\n");
	assert ok("const u: uint32 = 3000000000;\nconst i: int64 = u;\nconsole.log(i);\n");
}

test "numeric lattice: a contained unsigned argument takes the wider signed parameter" {
	assert ok("function t16(x: int16): int16 { return x; }\nconst u: uint8 = 7;\nconsole.log(t16(u));\n");
	assert ok("function ret(): int64 { const u: uint32 = 1; return u; }\nconsole.log(ret());\n");
}

test "numeric lattice: an overload takes the contained wider signed parameter" {
	assert ok("function ov(x: int32): string { return \"i\"; }\nfunction ov(x: string): string { return x; }\nconst u: uint8 = 2;\nconst s = ov(u);\nconsole.log(s);\n");
}

test "numeric lattice: an integer conversion that can change a value needs as" {
	assert errorCount("const u: uint8 = 3;\nconst i: int16 = u;\n") == 0;
	assert hasError("const n: int32 = -1;\nconst u: uint32 = n;\n", "-1 is outside [0, 4294967295]");
	assert hasError("const u: uint64 = 5;\nconst i: int64 = u;\n", "may exceed the target's maximum");
	assert hasError("const n: int32 = 300;\nconst b: int8 = n;\n", "300 is outside [-128, 127]");
}
