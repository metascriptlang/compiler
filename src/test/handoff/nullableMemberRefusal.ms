// Checker: a member read on a `T | null` is refused until the value is narrowed, and never offers the carrier fields

import { strictErrorCount, hasError } from "./helpers";

const FIND = "function find(s: string): string | null { return s.length > 0 ? s : null; }\nconst s = find(\"\");\n";
const POINT = "struct Point { x: int32; y: int32; }\nfunction at(n: int32): Point | null { return n > 0 ? { x: n, y: n } : null; }\nconst p = at(1);\n";
const SHAPE = "interface Shape { x: number; y: number; }\nfunction at(n: number): Shape | null { return n > 0 ? { x: n, y: n } : null; }\nconst p = at(1);\n";
const POSSIBLY_NULL = "is possibly 'null'";

test "the carrier fields of a nullable string are refused" {
	assert hasError(FIND + "console.log(s.present);", POSSIBLY_NULL);
	assert hasError(FIND + "console.log(s.value);", POSSIBLY_NULL);
}

test "a member of the payload on a nullable string asks for narrowing and offers no carrier field" {
	assert hasError(FIND + "console.log(s.length);", "narrow it with a null check");
	assert !hasError(FIND + "console.log(s.length);", "Available");
}

test "a nullable struct is refused the same way" {
	assert hasError(POINT + "console.log(p.present);", POSSIBLY_NULL);
	assert hasError(POINT + "console.log(p.value.x);", POSSIBLY_NULL);
	assert hasError(POINT + "console.log(p.x);", "narrow it with a null check");
	assert !hasError(POINT + "console.log(p.x);", "Available");
}

test "a nullable pointer-shaped object offers no carrier field" {
	assert !hasError(SHAPE + "console.log(p.present);", "Available: value");
	assert !hasError(SHAPE + "console.log(p.x);", "Available: value");
}

test "a refused read does not cascade into a second error on its result" {
	assert strictErrorCount(FIND + "console.log(s.value.length);") == 1;
}

test "a narrowed or chained read still compiles" {
	assert strictErrorCount(FIND + "if (s !== null) { console.log(s.length); }") == 0;
	assert strictErrorCount(FIND + "console.log(s!.length);\nconsole.log(s?.length);") == 0;
	assert strictErrorCount(POINT + "if (p !== null) { console.log(p.x); }\nconsole.log(p?.y);") == 0;
}
