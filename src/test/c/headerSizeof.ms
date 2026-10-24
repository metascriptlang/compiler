import { compileProjectToC, compileProjectToJS, MapEntry } from "../helpers";
import { setParserDefines, resetParserDefines } from "../../parser/context";
import { createDefineTable, applyDefineSwitch } from "../../compiler/defines";

const HEADER = "test/headerSizeof/shapes.h";
const MAIN = "test/headerSizeof/main.ms";
const SHAPES = "typedef struct { unsigned long size; int value; } Plain;\n"
	+ "typedef struct { Plain inner; char tag; } Nested;\n"
	+ "typedef union { unsigned long size; int value; } U;\n"
	+ "typedef struct { unsigned long size; int bits : 4; } Bits;\n"
	+ "typedef struct __attribute__((packed)) { unsigned long size; char c; } Packed;\n"
	+ "typedef struct { int tag; U value; } Colour;\n"
	+ "typedef struct { unsigned long size; Colour fg; } Styled;\n"
	+ "typedef struct { unsigned long size; int tag; union { int i; double d; }; } AnonU;\n";

function compileOn(backend: string, main: string): string {
	const t = createDefineTable();
	applyDefineSwitch(t, `-d:${backend}`);
	applyDefineSwitch(t, `-d:backend=${backend}`);
	applyDefineSwitch(t, "-d:os=linux");
	applyDefineSwitch(t, "-d:cpu=x86_64");
	setParserDefines(t);
	const entries: MapEntry[] = [{ entryPath: HEADER, entrySource: SHAPES }, { entryPath: MAIN, entrySource: main }];
	const out = backend == "js" ? compileProjectToJS(entries, MAIN) : compileProjectToC(entries, MAIN);
	resetParserDefines();
	return out;
}

function sizedInit(name: string, rest: string): string {
	return `import { ${name} } from "./shapes.h";\nconst v: ${name} = { size: sizeof ${name}, ${rest} };\nconsole.log(\`\${v.size}\`);\n`;
}

test "C: sizeof a complete header struct folds into its size_t field" {
	const c = compileOn("c", sizedInit("Plain", "value: 1"));
	assert !c.startsWith("ERROR"), c;
	assert c.contains("_Static_assert(sizeof(Plain) == 16");
	assert c.contains("_Static_assert(offsetof(Plain, value) == 8");
}

test "C: a header struct nesting a complete one is complete" {
	const c = compileOn("c", `import { Nested } from "./shapes.h";\nconst n: uint64 = sizeof Nested;\nconsole.log(\`\${n}\`);\n`);
	assert !c.startsWith("ERROR"), c;
	assert c.contains("_Static_assert(sizeof(Nested) == 24");
	assert c.contains("_Static_assert(offsetof(Nested, tag) == 16");
}

test "C: sizeof a header union and a struct holding one folds into a size_t field" {
	const c = compileOn("c", `import { U, Styled } from "./shapes.h";\nconst u: U = { size: sizeof U };\nconst s: Styled = { size: sizeof Styled };\nconsole.log(\`\${u.size} \${s.size}\`);\n`);
	assert !c.startsWith("ERROR"), c;
	assert c.contains("_Static_assert(sizeof(U) == 8");
	assert c.contains("_Static_assert(offsetof(U, value) == 0");
	assert c.contains("_Static_assert(sizeof(Colour) == 16");
	assert c.contains("_Static_assert(offsetof(Colour, value) == 8");
	assert c.contains("_Static_assert(sizeof(Styled) == 24");
}

test "C: sizeof a bitfield, packed or anonymous-union header struct into uint64 is refused by name" {
	for (const [name, rest] of [["Bits", "bits: 1"], ["Packed", "c: 1"], ["AnonU", "tag: 1"]]) {
		const c = compileOn("c", sizedInit(name, rest));
		assert c.contains(`takes 'sizeof ${name}', which is not a constant`), c;
		assert c.contains("write an explicit 'as uint64'"), c;
	}
}

test "C: sizeof an incomplete header struct with 'as uint64' compiles and asserts nothing" {
	const c = compileOn("c", `import { Bits } from "./shapes.h";\nconst n = sizeof Bits as uint64;\nconsole.log(\`\${n}\`);\n`);
	assert !c.startsWith("ERROR"), c;
	assert c.contains("sizeof(Bits)");
	assert !c.contains("_Static_assert(sizeof(Bits)");
}

test "JS: sizeof a complete header struct is still refused" {
	const js = compileOn("js", sizedInit("Plain", "value: 1"));
	assert js.startsWith("ERROR"), js;
	assert js.contains("sizeof"), js;
}
