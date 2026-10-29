import { fmt } from "../roundtrip";

test "fmt: an object stays on one line unless the source breaks after its brace" {
	assert fmt("const o1 = { a: 1, b: 2 };\n") == "const o1 = { a: 1, b: 2 };\n";
	assert fmt("const o2 = {\n\ta: 1, b: 2 };\n") == "const o2 = {\n\ta: 1,\n\tb: 2,\n};\n";
	assert fmt("const o3 = {\n\ta: 1 };\n") == "const o3 = {\n\ta: 1,\n};\n";
	assert fmt("const o5 = { a: { b: 1 } };\n") == "const o5 = { a: { b: 1 } };\n";
	assert fmt("const o6 = { a: [1, 2], b: () => 1 };\n") == "const o6 = { a: [1, 2], b: () => 1 };\n";
	assert fmt("const o7 = {a: 1,\n\tb: 2};\n") == "const o7 = { a: 1, b: 2 };\n";
	assert fmt("const o9 = { ...rest, a };\n") == "const o9 = { ...rest, a };\n";
	assert fmt("const o10 = {\n\t...rest };\n") == "const o10 = {\n\t...rest,\n};\n";
	assert fmt("const o12 = {\n};\n") == "const o12 = {};\n";
	assert fmt("foo({ a: 1, b: 2 });\n") == "foo({ a: 1, b: 2 });\n";
	assert fmt("foo({\n\ta: 1, b: 2 });\n") == "foo({\n\ta: 1,\n\tb: 2,\n});\n";
	assert fmt("foo({ a: 1 }, { b: 2 });\n") == "foo({ a: 1 }, { b: 2 });\n";
	assert fmt("const o16 = { a: 1, \"b-c\": 2, [k]: 3 };\n") == "const o16 = { a: 1, \"b-c\": 2, [k]: 3 };\n";
	assert fmt("const o18 = { a: { b: 1,\n\tc: 2 } };\n") == "const o18 = { a: { b: 1, c: 2 } };\n";
}

test "fmt: an object that does not fit breaks every member onto its own line" {
	assert fmt("const o8 = { aaaaaaaaaaaaaaaaaaaa: 1, bbbbbbbbbbbbbbbbbbbbbbbbb: 2, cccccccccccccccccccccc: 3, ddddddddddd: 4 };\n") == "const o8 = {\n\taaaaaaaaaaaaaaaaaaaa: 1,\n\tbbbbbbbbbbbbbbbbbbbbbbbbb: 2,\n\tcccccccccccccccccccccc: 3,\n\tddddddddddd: 4,\n};\n";
	assert fmt("const o17 = {\n\ta: { b: 1, c: 2 }, d: 3 };\n") == "const o17 = {\n\ta: { b: 1, c: 2 },\n\td: 3,\n};\n";
	assert fmt("const c2 = { name: \"param\", src: `\na\n` };\n") == "const c2 = {\n\tname: \"param\",\n\tsrc: `\na\n`,\n};\n";
}

test "fmt: an object pattern ignores the source line break and breaks when it does not fit" {
	assert fmt("const { a1, b1 } = obj;\n") == "const { a1, b1 } = obj;\n";
	assert fmt("const {\n\ta2, b2 } = obj;\n") == "const { a2, b2 } = obj;\n";
	assert fmt("const { a5 = 1, b5 = 2 } = obj;\n") == "const { a5 = 1, b5 = 2 } = obj;\n";
	assert fmt("const { a6, ...rest6 } = obj;\n") == "const { a6, ...rest6 } = obj;\n";
	assert fmt("const { aaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccc, ddddddddddd } = obj;\n") == "const {\n\taaaaaaaaaaaaaaaaaaaa,\n\tbbbbbbbbbbbbbbbbbbbbbbbbb,\n\tcccccccccccccccccccccc,\n\tddddddddddd,\n} = obj;\n";
	assert fmt("const { aaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccc, ...ddddddddddd } = obj;\n") == "const {\n\taaaaaaaaaaaaaaaaaaaa,\n\tbbbbbbbbbbbbbbbbbbbbbbbbb,\n\tcccccccccccccccccccccc,\n\t...ddddddddddd\n} = obj;\n";
	assert fmt("for (const { a, b } of list) { f(); }\n") == "for (const { a, b } of list) {\n\tf();\n}\n";
}

test "fmt: an object pattern holding a nested pattern expands" {
	assert fmt("const { a3, b3: { c3 } } = obj;\n") == "const {\n\ta3,\n\tb3: { c3 },\n} = obj;\n";
	assert fmt("const { a4, b4: [c4] } = obj;\n") == "const {\n\ta4,\n\tb4: [c4],\n} = obj;\n";
	assert fmt("const { a7, b7: {} } = obj;\n") == "const {\n\ta7,\n\tb7: {},\n} = obj;\n";
	assert fmt("const { a8, b8: [] } = obj;\n") == "const {\n\ta8,\n\tb8: [],\n} = obj;\n";
}
