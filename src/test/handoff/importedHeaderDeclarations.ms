import { inlineHeaderImports, createFileSystemProvider } from "../../module/loader";
import { ModuleError } from "../../module/graph";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { NodeKind, ProgramData, FunctionDeclData, TypeAliasDeclData } from "../../ast/node";
import { writeFile, ensureDir, removeAll } from "std/fs";
import { cwd } from "std/process";

test "header include topology preserves declared symbols and a single shared typedef" {
	const root = cwd() + "/out/headerDeclarations-" + performance.now().toString();
	ensureDir(root + "/lib/sub");
	defer removeAll(root);
	assert writeFile(root + "/lib/a.h", "typedef struct Resource* ResourceRef;\nint openResource(ResourceRef r);\n").ok, "write lib/a.h";
	assert writeFile(root + "/lib/b.h", "int closeResource(ResourceRef r);\n#define TAIL_MACRO(x) x").ok, "write lib/b.h";
	assert writeFile(root + "/lib/all.h", "#include <lib/a.h>\n#include <lib/b.h>\n").ok, "write lib/all.h";
	assert writeFile(root + "/lib/top.h", "#include \"sub/outer.h\"\n").ok, "write lib/top.h";
	assert writeFile(root + "/lib/sub/outer.h", "#include \"inner.h\"\n").ok, "write lib/sub/outer.h";
	assert writeFile(root + "/lib/sub/inner.h", "int siblingValue(void);\n").ok, "write lib/sub/inner.h";
	assert writeFile(root + "/lib/shared.h", "typedef struct Resource* ResourceRef;\nint sharedResource(ResourceRef r);\n").ok, "write lib/shared.h";
	const sources = [
		"import { openResource, closeResource } from \"./lib/all.h\";",
		"import { siblingValue } from \"./lib/top.h\";",
		"import { openResource } from \"./lib/a.h\"; import { sharedResource } from \"./lib/shared.h\";",
	];
	const expected = ["openResource,closeResource", "siblingValue", "openResource,sharedResource"];
	for (let i = 0; i < sources.length; i += 1) {
		const errors: ModuleError[] = [];
		const inlined = inlineHeaderImports(sources[i], root + "/main.ms", createFileSystemProvider(), false, errors);
		assert errors.length == 0, sources[i];
		const parsed = parseSource(inlined);
		assert parsed.ok, sources[i];
		const functions: string[] = [];
		let aliases: int32 = 0;
		for (const statement of (parsed.value.data as ProgramData).programStmts) {
			if (statement.kind == NodeKind.FunctionDecl) functions.push((statement.data as FunctionDeclData).fnName);
			if (statement.kind == NodeKind.TypeAliasDecl && (statement.data as TypeAliasDeclData).aliasName == "ResourceRef") aliases += 1;
		}
		for (const name of expected[i].split(",")) {
			let count: int32 = 0;
			for (const found of functions) if (found == name) count += 1;
			assert count == 1, name;
		}
		assert aliases == (i == 1 ? 0 : 1), sources[i];
	}
}
