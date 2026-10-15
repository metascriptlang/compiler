import { resetBuildState } from "../../compiler/buildSession";
import { MapEntry, createMapProvider, loadModuleGraph, canonicalModulePath } from "../../module/loader";
import { checkModuleGraph } from "../../checker/orchestrator";
import { lookupModuleProgram, lookupModuleCtx } from "../../checker/instantiate";
import { Node, NodeKind, MemberExprData } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";

// a.ms reaches a `Box` only through `make()` from b.ms; c.ms exports another `Box`
// and is imported first, so a lookup of the spelling `Box` meets c.ms before b.ms.
function memberModuleOf(boxModule: string): string {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: canonicalModulePath("/memberContainer/a.ms"), entrySource: "import \"./c\";\nimport { make } from \"./b\";\nconst s = make().size;\n" },
		{ entryPath: canonicalModulePath("/memberContainer/b.ms"), entrySource: boxModule },
		{ entryPath: canonicalModulePath("/memberContainer/c.ms"), entrySource: "export class Box { size: int32 = 4; }\n" },
	];
	const graph = loadModuleGraph(entries[0].entryPath, createMapProvider(entries));
	checkModuleGraph(graph, "");
	const program = lookupModuleProgram(entries[0].entryPath);
	if (program == null) return "no program";
	const found = memberAccesses(program, []);
	if (found.length != 1 || found[0].resolvedSym == null) return "no member symbol";
	return found[0].resolvedSym.modulePath;
}

function entryErrors(entrySource: string): string[] {
	resetBuildState();
	const entries: MapEntry[] = [
		{ entryPath: canonicalModulePath("/memberContainer/a.ms"), entrySource },
		{ entryPath: canonicalModulePath("/memberContainer/b.ms"), entrySource: "export class Box { size: int32 = 3; }\nexport function make(): Box { return new Box(); }\n" },
	];
	const graph = loadModuleGraph(entries[0].entryPath, createMapProvider(entries));
	checkModuleGraph(graph, "");
	const ctx = lookupModuleCtx(entries[0].entryPath);
	const messages: string[] = [];
	if (ctx == null) { messages.push("no module context"); return messages; }
	for (const e of ctx.errors) messages.push(e.message);
	return messages;
}

function memberAccesses(node: Node, found: Node[]): Node[] {
	if (node.kind == NodeKind.MemberExpr && (node.data as MemberExprData).property == "size") found.push(node);
	forEachChild(node, (child: Node): void => { memberAccesses(child, found); });
	return found;
}

test "memberContainer: a class field names the module of the class the value has, not of another class spelled the same" {
	const where = memberModuleOf("export class Box { size: int32 = 3; }\nexport function make(): Box { return new Box(); }\n");
	assert where == canonicalModulePath("/memberContainer/b.ms"), where;
}

test "memberContainer: an interface field names the module of the interface the value has, not of another type spelled the same" {
	const where = memberModuleOf("export interface Box { size: int32; }\nexport function make(): Box { return { size: 3 }; }\n");
	assert where == canonicalModulePath("/memberContainer/b.ms"), where;
}

test "memberContainer: a field the value's class lacks is refused, not read from a class in scope spelled the same" {
	const messages = entryErrors("import { make } from \"./b\";\nclass Box { size: int32 = 1; extra: int32 = 5; }\nconst local = new Box();\nconst n = make().extra + local.size;\n");
	assert messages.length == 1 && messages[0].contains("'extra'"), messages.join("\n");
}

test "memberContainer: a field the value's class declares is read with a class in scope spelled the same" {
	const messages = entryErrors("import { make } from \"./b\";\nclass Box { extra: int32 = 5; }\nconst local = new Box();\nconst n = make().size + local.extra;\n");
	assert messages.length == 0, messages.join("\n");
}
