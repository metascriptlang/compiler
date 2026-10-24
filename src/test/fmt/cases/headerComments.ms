import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const predicate = "function isText(x: string | int32): /* c */ x is string {\n\treturn typeof x === \"string\";\n}\n";
const lineComment = "function mustBeText(x: string | int32): asserts x // c\n\tis string {\n\tif (typeof x !== \"string\") throw new Error(\"not text\");\n}\n";
const members = "class Box {\n\tconstructor(n: int32 /* size */) {\n\t\tthis.n = n;\n\t}\n\tasync load(): /* c */ Promise<int32> {\n\t\treturn this.n;\n\t}\n\tprivate get value(): /* g */ int32 {\n\t\treturn this.n;\n\t}\n}\n";
const expressions = "const f = async /* c */ function(): Promise<int32> { return 1; };\nconst g = async (x: int32): /* c */ Promise<int32> => {\n\treturn x;\n};\n";
const afterParams = "function record(\n\tkey: string,\n\tcount: int32, // seen\n\tdone: boolean\n): /* after */ void {\n\tg();\n}\n";
const forOf = "for (const x /* c */ of xs) sum += x;\nfor (const x of /* c */ xs) {\n\tsum += x;\n}\n";

test "fmt: a comment inside a function's return type stays in place" {
	assert assertFmtLossless(predicate);
	assert assertFmtIdempotent(predicate);
	assert assertFmtLossless(lineComment);
	assert assertFmtIdempotent(lineComment);
}

test "fmt: a comment inside a constructor, method or accessor header stays in place" {
	assert assertFmtLossless(members);
	assert assertFmtIdempotent(members);
}

test "fmt: a comment inside a function expression or block arrow header stays in place" {
	assert assertFmtLossless(expressions);
	assert assertFmtIdempotent(expressions);
}

test "fmt: a comment after a commented parameter list stays after it" {
	assert assertFmtLossless(afterParams);
	assert assertFmtIdempotent(afterParams);
}

test "fmt: a comment inside a for-of head stays in place" {
	assert assertFmtLossless(forOf);
	assert assertFmtIdempotent(forOf);
}
