// A scalar imported under its C name (`extern type CSize: uint64 from "size_t"`) is spelled as that
// name in C, so a pointer to it matches the C prototype (`size_t *`, `char **`) that a strict
// C compiler checks. The base keeps its checker meaning: the imported name and the base interchange.

import { builtinIncludeDir } from "../../utils/path";
import { compileToC, compileProjectToCWithStd } from "../helpers";

const prelude = "extern type CChar: uint8 from \"char\";\nextern type CSize: uint64 from \"size_t\";\nextern struct Node;\n";

test "importedScalarSpelling: a variable of an imported scalar is spelled by its C name" {
	const result = compileToC(prelude + "let cap: CSize = 0;\nlet line: Ptr<CChar> = null as Ptr<CChar>;\nconsole.log(cap);");
	assert result.ok;
	assert result.value.contains("size_t cap__");
	assert result.value.contains("char* line__");
	assert !result.value.contains("uint64_t cap__");
	assert !result.value.contains("typedef struct CSize");
	assert !result.value.contains("typedef struct CChar");
}

test "importedScalarSpelling: a pointer to an imported scalar and one to its base are different C types" {
	const result = compileToC(prelude + "let a: Ptr<CSize> = null as Ptr<CSize>;\nlet b: Ptr<uint64> = null as Ptr<uint64>;\nlet c: uint64 = 1;\nconsole.log(c);");
	assert result.ok;
	assert result.value.contains("size_t* a__");
	assert result.value.contains("uint64_t* b__");
	assert result.value.contains("uint64_t c__");
}

test "importedScalarSpelling: a ref parameter passes the address of the imported name" {
	const result = compileToC(prelude + "extern function getline(ref line: Ptr<CChar>, ref cap: CSize, file: Ptr<Node>): int64;\n"
		+ "let line: Ptr<CChar> = null as Ptr<CChar>;\nlet cap: CSize = 0;\nconst n = getline(line, cap, null as Ptr<Node>);\nconsole.log(n);");
	assert result.ok;
	assert result.value.contains("char* line__");
	assert result.value.contains("size_t cap__");
	assert result.value.contains("getline((&(line__");
}

test "importedScalarSpelling: const char and a struct pointer keep their own pointee" {
	const result = compileToC(prelude + "extern function names(ref v: cstring, n: Ptr<CSize> | null): int32;\nextern function nodes(out slot: Ptr<Node>): int32;\n"
		+ "let v: cstring = \"a\";\nlet n: CSize = 0;\nlet slot: Ptr<Node>;\nconsole.log(names(v, n));\nconsole.log(nodes(slot));");
	assert result.ok;
	assert result.value.contains("const char* v__");
	assert result.value.contains("size_t n__");
	assert result.value.contains("Node* slot__");
}

test "importedScalarSpelling: the imported name and its base interchange" {
	const result = compileToC(prelude + "let a: CSize = 3;\nconst b: uint64 = a + 1;\nlet c: CSize = b;\nlet p: Ptr<CChar> = null as Ptr<CChar>;\nconst q: Ptr<uint8> = p;\nconsole.log(c);");
	assert result.ok;
}

test "importedScalarSpelling: a char ** parameter takes null or the address of a pointer variable" {
	const result = compileToC(prelude + "extern function strtol(s: cstring, end: Ptr<Ptr<CChar>> | null, base: int32): int64;\n"
		+ "let end: Ptr<CChar> = null as Ptr<CChar>;\nconsole.log(strtol(\"42x\", null, 10));\nconsole.log(strtol(\"42x\", end, 10));");
	assert result.ok;
	assert result.value.contains("char* end__");
	assert result.value.contains("strtol(") && result.value.contains("(&(end__");
}

test "importedScalarSpelling: the address of a pointer local does not outlive its frame" {
	const result = compileToC(prelude + "function leak(): Ptr<Ptr<CChar>> {\n\tlet p: Ptr<CChar> = null as Ptr<CChar>;\n\treturn p as Ptr<Ptr<CChar>>;\n}\nconsole.log(leak() == null);");
	assert !result.ok;
	assert result.error.contains("escapes its stack frame");
}

test "importedScalarSpelling: the emitted C never includes a parse-only stub header or typedefs a standard scalar" {
	const header = "#include <stddef.h>\n#include <stdint.h>\nsize_t sz(size_t *n);\nint64_t wide(void);\n";
	const c = compileProjectToCWithStd([
		{ entryPath: "/proj/main.ms", entrySource: "import { sz, wide } from \"./a.h\";\nlet n: uint64 = 0;\nconsole.log(wide());\n" },
		{ entryPath: "/proj/a.h", entrySource: header },
	], "/proj/main.ms");
	assert !c.startsWith("ERROR"), c;
	assert !c.contains("cparse/include");
	for (const name of ["int64_t", "uint64_t", "intmax_t", "uintptr_t", "size_t"]) {
		assert !c.contains("typedef " + name), name;
		assert !c.contains(" " + name + ";\ntypedef"), name;
	}
}

test "importedScalarSpelling: an @include of a standard header reaches the C by the author's name" {
	const c = compileProjectToCWithStd([
		{ entryPath: "/proj/main.ms", entrySource: "import { sz } from \"./a.h\";\n@include(\"stdint.h\");\nconsole.log(sz(null));\n" },
		{ entryPath: "/proj/a.h", entrySource: "#include <stdint.h>\nint64_t sz(int64_t *n);\n" },
	], "/proj/main.ms");
	assert !c.startsWith("ERROR"), c;
	assert !c.contains("cparse/include");
	assert c.contains("#include \"stdint.h\"") || c.contains("#include <stdint.h>");
}

test "importedScalarSpelling: std/crypto encoding emits no parse-only stub include" {
	const c = compileProjectToCWithStd([
		{ entryPath: "/proj/main.ms", entrySource: "import { encodeHex } from \"std/crypto/encoding\";\nconst d: uint8[] = [1, 2];\nconsole.log(d.encodeHex());\n" },
	], "/proj/main.ms");
	assert !c.startsWith("ERROR"), c;
	assert !c.contains("cparse/include");
}

test "importedScalarSpelling: an @include that names a parse-only stub header never reaches the emitted C" {
	const c = compileProjectToCWithStd([
		{ entryPath: "/proj/main.ms", entrySource: "@include(\"" + builtinIncludeDir() + "/stdint.h\");\nconsole.log(1);\n" },
	], "/proj/main.ms");
	assert !c.startsWith("ERROR"), c;
	assert !c.contains("cparse/include");
}
