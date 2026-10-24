import { createFileSystemProvider, loadModuleGraph, canonicalModulePath } from "../../module/loader";
import { Module } from "../../module/graph";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { NodeKind, ProgramData, FunctionDeclData, TypeAliasDeclData, ExportDeclData, Node } from "../../ast/node";
import { writeFile, ensureDir, removeAll } from "std/fs";
import { cwd } from "std/process";

function declaredNames(mod: Module): string[] {
	const names: string[] = [];
	const parsed = parseSource(mod.source);
	if (!parsed.ok) return names;
	for (const statement of (parsed.value.data as ProgramData).programStmts) {
		let decl: Node = statement;
		if (decl.kind == NodeKind.ExportDecl) decl = (decl.data as ExportDeclData).exportedDecl;
		if (decl == null) continue;
		if (decl.kind == NodeKind.FunctionDecl) names.push((decl.data as FunctionDeclData).fnName);
		if (decl.kind == NodeKind.TypeAliasDecl) names.push((decl.data as TypeAliasDeclData).aliasName);
	}
	return names;
}

test "each header module declares what its own file writes, once" {
	const root = canonicalModulePath(cwd() + "/out/headerDeclarations-" + performance.now().toString());
	ensureDir(root + "/lib/sub");
	defer removeAll(root);
	assert writeFile(root + "/lib/a.h", "typedef struct Resource* ResourceRef;\nint openResource(ResourceRef r);\n").ok, "write lib/a.h";
	assert writeFile(root + "/lib/b.h", "#include \"a.h\"\nint closeResource(ResourceRef r);\n#define TAIL_MACRO(x) x").ok, "write lib/b.h";
	assert writeFile(root + "/lib/all.h", "#include <lib/a.h>\n#include <lib/b.h>\n").ok, "write lib/all.h";
	assert writeFile(root + "/lib/top.h", "#include \"sub/outer.h\"\n").ok, "write lib/top.h";
	assert writeFile(root + "/lib/sub/outer.h", "#include \"inner.h\"\n").ok, "write lib/sub/outer.h";
	assert writeFile(root + "/lib/sub/inner.h", "int siblingValue(void);\n").ok, "write lib/sub/inner.h";
	assert writeFile(root + "/main.ms", "import { openResource, closeResource } from \"./lib/all.h\";\nimport { siblingValue } from \"./lib/top.h\";\n").ok, "write main.ms";
	const graph = loadModuleGraph(root + "/main.ms", createFileSystemProvider());
	assert graph.errors.length == 0;
	const expected = [
		"/lib/a.h=ResourceRef,openResource", "/lib/b.h=closeResource", "/lib/all.h=",
		"/lib/top.h=", "/lib/sub/inner.h=siblingValue",
	];
	for (const row of expected) {
		const eq = row.indexOf("=");
		const path = root + row.slice(0, eq);
		let found = false;
		for (const mod of graph.modules) {
			if (mod.path != path) continue;
			found = true;
			assert mod.errors.length == 0, `${path}: ${mod.errors.length > 0 ? mod.errors[0].message : ""}`;
			assert declaredNames(mod).join(",") == row.slice(eq + 1, row.length), `${path}: ${declaredNames(mod).join(",")}`;
		}
		assert found, path;
	}
}
