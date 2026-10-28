// `instanceof` on a nullable union of a value and a class tests presence, then the held member.

import { compileToC } from "../helpers";

const row = "class Row { value: int32; constructor(value: int32) { this.value = value; } }\n";

test "instanceof on a nullable number or class union reads the payload only when present" {
	const result = compileToC(row + "function mk(k: int32): number | Row | null { return k == 0 ? new Row(7) : null; }\nconst c: number | Row | null = mk(0);\nconsole.log(c instanceof Row);");
	assert result.ok;
	assert result.value.contains(".present && ");
	assert result.value.contains(".value._tag == 0");
}

test "instanceof on a nullable string or class field reads the field's payload only when present" {
	const result = compileToC(row + "class Holder { v: string | Row | null; constructor(v: string | Row | null) { this.v = v; } }\nconst h = new Holder(\"s\");\nconsole.log(h.v instanceof Row);");
	assert result.ok;
	assert result.value.contains("v.present && ");
	assert result.value.contains("v.value._tag == 0");
}
