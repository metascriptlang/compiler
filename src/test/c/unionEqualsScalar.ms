// A union compared with a scalar tests the held member and compares that member.

import { compileToC } from "../helpers";

const pick = "function pick(k: int32): int32 | string { return k > 0 ? 2 : \"s\"; }\nconst w = pick(1);\n";

test "a union equal to a number calls the member comparison routine" {
	const result = compileToC(pick + "console.log(w === 2, 2 !== w);");
	assert result.ok;
	assert result.value.contains("msUnionEq_");
	assert result.value.contains("._tag == 0");
}

test "a union equal to a string tests the string member" {
	const result = compileToC(pick + "console.log(w === \"s\");");
	assert result.ok;
	assert result.value.contains("._tag == 1");
}
