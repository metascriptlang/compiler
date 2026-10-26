// A scalar imported under its C name (`extern type CSize: uint64 from "size_t"`) is spelled as that
// name in C, so a pointer to it matches the C prototype (`size_t *`, `char **`) that a strict
// C compiler checks. The base keeps its checker meaning: the imported name and the base interchange.

import { compileToC } from "../helpers";

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
