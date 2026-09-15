// Route 15j: Checker — a function value where its result is needed is an error, not always-true, NaN or garbage

import { strictErrorCount, hasError } from "./helpers";

const FN = "function mk(): () => number { return () => 3; }\nconst f = mk();\n"
	+ "function mkArr(): () => number[] { return () => [1, 2]; }\nconst g = mkArr();\n"
	+ "const arr: number[] = [1, 2];\n";
const TRUTHY = "a function is always truthy";

test "a function tested for truthiness is an error" {
	assert hasError(FN + "if (f) { }", TRUTHY);
	assert hasError(FN + "while (f) { break; }", TRUTHY);
	assert hasError(FN + "const t = f ? 1 : 2;", TRUTHY);
	assert hasError(FN + "const n = !f;", TRUTHY);
	assert hasError(FN + "const a = f && true;", TRUTHY);
}

test "a nullable function and a called function are tested as usual" {
	assert strictErrorCount(FN + "function h(cb: (() => number) | null): number { if (cb) { return cb(); } return 0; }\nif (f() > 1) { }\nconst ok = !(f() > 1);") == 0;
}

test "a function operand of unary minus is an error" {
	assert hasError(FN + "const u = -f;", "unary '-' needs a numeric operand");
	assert strictErrorCount(FN + "const n2: number = 2;\nconst u2 = -n2;\nconst u3 = -f();") == 0;
}

test "a compound assignment checks its operands like the binary operator" {
	assert hasError(FN + "let t: number = 1;\nt += f;", "operator '+=' cannot be applied");
	assert strictErrorCount(FN + "let t: number = 1;\nt += f();\nlet s: string = \"a\";\ns += 1;") == 0;
}

test "indexing a function or indexing an array with a function is an error" {
	assert hasError(FN + "const x = g[0];", "a function value cannot be indexed");
	assert hasError(FN + "const y = arr[f];", "an array index must be a number");
	assert strictErrorCount(FN + "const i: int32 = 1;\nconst z = arr[i];\nconst w = g()[0];\nconst s: string = \"ab\";\nconst ch = s[0];") == 0;
}

test "spreading a function is an error" {
	assert hasError(FN + "const sp: number[] = [...g];", "a function value cannot be spread");
	assert strictErrorCount(FN + "const sp: number[] = [...arr];") == 0;
}

test "a switch case that cannot equal the discriminant is an error" {
	assert hasError(FN + "switch (f) { case 1: break; default: break; }", "is not comparable to the switch value");
	assert strictErrorCount(FN + "const n: number = 1;\nswitch (n) { case 1: break; case 2: break; default: break; }\nconst s: string = \"a\";\nswitch (s) { case \"a\": break; default: break; }") == 0;
}
