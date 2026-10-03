import { compileToJS } from "../helpers";

type Byte = uint8;
function wide(n: int32): int32 { return n; }

test "aliasNarrowingCast: a narrowing cast to an alias wraps on C" {
	const b = wide(300) as Byte;
	assert b == 44;
}

test "aliasNarrowingCast: a narrowing cast to an alias masks on JS" {
	const r = compileToJS("type Byte = uint8;\nfunction f(v: int32): Byte { return v as Byte; }\nconsole.log(f(300));\n");
	assert r.ok;
	if (r.ok) { assert r.value.contains("& 255"); }
}
