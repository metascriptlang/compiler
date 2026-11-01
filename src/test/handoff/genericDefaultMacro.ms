import {
	Node, NodeKind, ProgramData, TypeAnnotationData, SymbolKind, TypeKind,
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { nodeToValue, valueToNode } from "../../compiler/meta/bridge";
import { createStructHeap, createArrayHeap } from "../../raiser/value";
import { createContext, isExportedBy } from "../../checker/context";
import { defineTypeParams } from "../../checker/resolvePass";
import { makeSymbol, lookupSymbol } from "../../checker/symbol";
import { unknownType, createGenericParam, stringType, peelToRepr } from "../../checker/types";
import { checkProjectDiagnostics, MapEntry } from "../helpers";
import {
	lookupModuleCtx, declaringModuleCtx, registerModuleCtx,
	createModuleCtxRegistry, swapModuleCtxRegistry,
} from "../../checker/instantiate";
import { installBodyReadSink } from "../../checker/bodyReads";
import { canonicalModulePath } from "../../module/loader";

test "genericDefaultMacro: defining scope records exact foreign body-read identity" {
	const caller = createContext();
	caller.modulePath = canonicalModulePath("test/defaultCaller.ms");
	const home = createContext();
	home.modulePath = canonicalModulePath("test/defaultHome.ms");
	const original = makeSymbol("Original", SymbolKind.TypeAlias, unknownType(), false);
	original.modulePath = home.modulePath;
	const seen: string[] = [];
	const outerRegistry = swapModuleCtxRegistry(createModuleCtxRegistry());
	const outerSink = installBodyReadSink((path: string): void => {
		seen.push(path);
	});
	try {
		registerModuleCtx(home.modulePath, home);
		assert declaringModuleCtx(caller, original) == home;
		assert seen.length == 1 && seen[0] == home.modulePath;
		assert declaringModuleCtx(home, original) == home;
		assert seen.length == 1;
		original.modulePath = "";
		assert declaringModuleCtx(caller, original) == caller;
		assert seen.length == 1;
		original.modulePath = canonicalModulePath("test/missingDefaultHome.ms");
		assert declaringModuleCtx(caller, original) == null;
		assert seen.length == 2 && seen[1] == original.modulePath;
	} finally {
		installBodyReadSink(outerSink);
		swapModuleCtxRegistry(outerRegistry);
	}
}

function declaration(source: string): Node {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error(parsed.error);
	return (parsed.value.data as ProgramData).programStmts[0];
}

test "genericDefaultMacro: wire preserves aligned syntax with type AST on or off" {
	for (const keyword of ["type", "interface", "struct", "class"]) {
		const body = keyword == "type" ? " = U;" : " {}";
		const source = declaration(keyword + " Pair<T, U = T[]>" + body);
		for (const includeTypeAst of [true, false]) {
			const objects = createStructHeap();
			const arrays = createArrayHeap();
			const back = valueToNode(
				nodeToValue(source, objects, arrays, includeTypeAst),
				objects, arrays, source.location,
			);
			assert back.genericDefaults != null, keyword;
			const defaults = back.genericDefaults!;
			assert defaults.length == 2 && defaults[0] == null, keyword;
			const annotation = defaults[1];
			assert annotation != null && annotation.kind == NodeKind.TypeAnnotation;
			assert (annotation.data as TypeAnnotationData).annotationType == "T[]";
			const originalAnnotation = source.genericDefaults![1];
			assert originalAnnotation != null;
			assert annotation.location.line == originalAnnotation.location.line;
			assert back.typeArg == source.typeArg, keyword;
		}
	}
}

test "genericDefaultMacro: wire defaults check with fresh local parameter identities" {
	const source = declaration("type Pair<T, U = T> = U;");
	const original = makeSymbol("Pair", SymbolKind.TypeAlias, unknownType(), false);
	original.declNode = source;
	defineTypeParams(createContext(), original, "T,U");
	const objects = createStructHeap();
	const arrays = createArrayHeap();
	const back = valueToNode(nodeToValue(source, objects, arrays),
		objects, arrays, source.location);
	const copied = makeSymbol("Pair", SymbolKind.TypeAlias, unknownType(), false);
	copied.declNode = back;
	const ctx = createContext();
	defineTypeParams(ctx, copied, "T,U");
	assert ctx.errors.length == 0;
	assert copied.typeParams[1].typeParamDefault == copied.typeParams[0];
	assert copied.typeParams[0] != original.typeParams[0];
	assert original.typeParams[1].typeParamDefault == original.typeParams[0];
}

test "genericDefaultMacro: semantic type handles already retain checked defaults" {
	const source = declaration("type Pair<T> = T;");
	source.genericDefaults = null;
	const parameter = createGenericParam("T");
	parameter.typeParamDefault = stringType();
	source.nodeType = parameter;
	for (const includeTypeAst of [true, false]) {
		const objects = createStructHeap();
		const arrays = createArrayHeap();
		const back = valueToNode(
			nodeToValue(source, objects, arrays, includeTypeAst),
			objects, arrays, source.location,
		);
		const reflected = back.nodeType;
		assert reflected != null && reflected == parameter;
		assert reflected.typeParamDefault == parameter.typeParamDefault;
		assert back.genericDefaults == null;
	}
}

const parameters = "T, U = T, V = Foreign, W = [T, Foreign]";

function generatedDefaults(macroSource: string, publicDeclaration: boolean = true): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/mac.ms", entrySource: macroSource },
		{
			entryPath: "test/main.ms",
			entrySource: `import { produce } from "./mac";
				type Foreign = int32;
				type T = int64;
				produce();`,
		},
	];
	const problems = checkProjectDiagnostics(entries, "test/main.ms")
		.filter((message: string): boolean =>
			!message.endsWith("is declared but never used") &&
			!message.endsWith("is imported but never used"));
	if (problems.length != 0) return problems.join(" | ");
	const ctx = lookupModuleCtx(canonicalModulePath("test/main.ms"));
	if (ctx == null) return "no expansion module";
	const produced = lookupSymbol(ctx.table, "Produced");
	if (produced == null) return "no Produced declaration";
	if (publicDeclaration && !isExportedBy(ctx, produced)) {
		return "Produced is not public";
	}
	if (produced.typeParams.length != 4) return "lost generic parameters";
	if (produced.typeParams[1].typeParamDefault != produced.typeParams[0]) {
		return "earlier parameter captured an outer T";
	}
	const foreign = produced.typeParams[2].typeParamDefault;
	if (foreign == null || peelToRepr(foreign)!.kind != TypeKind.String) {
		return "foreign default captured caller's Foreign";
	}
	const tuple = produced.typeParams[3].typeParamDefault;
	if (tuple == null || tuple.kind != TypeKind.Tuple) return "lost tuple default";
	if (tuple.typeChildren[0] != produced.typeParams[0]) {
		return "tuple retained the source's old parameter identity";
	}
	if (peelToRepr(tuple.typeChildren[1])!.kind != TypeKind.String) {
		return "tuple foreign name captured caller's Foreign";
	}
	const home = lookupModuleCtx(canonicalModulePath("test/mac.ms"));
	if (home == null) return "no source module";
	const original = lookupSymbol(home.table, "Original");
	if (original != null) {
		if (original.typeParams[0] == produced.typeParams[0]) {
			return "copied parameter reused the original identity";
		}
		if (original.typeParams[1].typeParamDefault != original.typeParams[0]) {
			return "getImpl mutated the original default";
		}
	}
	return "";
}

test "genericDefaultMacro: getImpl keeps foreign defaults and rebinds local tuple parameters" {
	const failure = generatedDefaults(`
import { Node, NodeKind, getImpl, bindSym } from "std/meta";
type Foreign = string;
type T = boolean;
export type Original<${parameters}> = W;
export macro produce(): Node {
	const impl = getImpl(bindSym("Original"))!;
	const defaults = impl.genericDefaults;
	if (defaults == null || defaults.length != 4) {
		throw new Error("getImpl erased default syntax");
	}
	const foreign = defaults[2];
	if (foreign == null || foreign.annotationType != "Foreign") {
		throw new Error("getImpl erased the annotation text");
	}
	const checked = foreign.nodeType;
	if (checked == null || checked.kind != NodeKind.Identifier || checked.name != "string") {
		throw new Error("getImpl erased the checked default type");
	}
	impl.aliasName = "Produced";
	return {
		kind: NodeKind.SpliceMany, line: 1, column: 1,
		spliceNodes: [{
			kind: NodeKind.ExportDecl, line: 1, column: 1, exportedDecl: impl,
		}],
	};
}
`);
	assert failure == "", failure;
}

test "genericDefaultMacro: quoted declaration defaults bind foreign names but not outer T" {
	for (const keyword of ["type", "interface", "struct", "class"]) {
		const body = keyword == "type" ? " = W;" : " {}";
		const failure = generatedDefaults(`
import { Node, NodeKind } from "std/meta";
type Foreign = string;
type T = boolean;
export macro produce(): Node {
	const tree: Node = quote { export ${keyword} Produced<${parameters}>${body} };
	return {
		kind: NodeKind.SpliceMany, line: 1, column: 1,
		spliceNodes: tree.statements,
	};
}
`);
		assert failure == "", keyword + ": " + failure;
	}
}

test "genericDefaultMacro: imported bare last splice declaration keeps defaults" {
	for (const keyword of ["type", "interface", "struct", "class"]) {
		const body = keyword == "type" ? " = W;" : " {}";
		const failure = generatedDefaults(`
import { Node, NodeKind } from "std/meta";
type Foreign = string;
type T = boolean;
export macro produce(): Node {
	const tree: Node = quote { ${keyword} Produced<${parameters}>${body} };
	return {
		kind: NodeKind.SpliceMany, line: 1, column: 1,
		spliceNodes: tree.statements,
	};
}
`, false);
		assert failure == "", keyword + ": " + failure;
	}
}

test "genericDefaultMacro: same-module bare last adoption retains defaults" {
	let failures = "";
	for (const keyword of ["type", "interface", "struct", "class"]) {
		const body = keyword == "type" ? " = W;" : " {}";
		const source = `
import { Node, NodeKind } from "std/meta";
type Foreign = string;
type T = boolean;
macro produce(): Node {
	const tree: Node = quote { ${keyword} Produced<${parameters}>${body} };
	const defaults = tree.statements[0].genericDefaults;
	if (defaults == null || defaults.length != 4 || defaults[0] != null) {
		throw new Error("quote erased default header before collection");
	}
	return {
		kind: NodeKind.SpliceMany, line: 1, column: 1,
		spliceNodes: tree.statements,
	};
}
produce();
const force = [] as Produced<int32, string, string, [int32, string]>[];
`;
		const entries: MapEntry[] = [
			{ entryPath: "test/adoption.ms", entrySource: source },
		];
		const problems = checkProjectDiagnostics(entries, "test/adoption.ms")
			.filter((message: string): boolean =>
				!message.endsWith("is declared but never used") &&
				!message.endsWith("is imported but never used"));
		assert problems.length == 0, keyword + ": " + problems.join(" | ");
		const ctx = lookupModuleCtx(canonicalModulePath("test/adoption.ms"));
		assert ctx != null, keyword;
		const produced = lookupSymbol(ctx.table, "Produced");
		assert produced != null && produced.typeParams.length == 4, keyword;
		const params = produced.typeParams;
		if (produced.declNode == null || produced.declNode.genericDefaults == null) {
			failures += keyword + ": lost default header; ";
		}
		if (params[1].typeParamDefault != params[0]) {
			failures += keyword + ": lost earlier parameter identity; ";
		}
		const foreign = params[2].typeParamDefault;
		if (foreign == null || peelToRepr(foreign)!.kind != TypeKind.String) {
			failures += keyword + ": lost concrete source default; ";
		}
		const tuple = params[3].typeParamDefault;
		if (tuple == null || tuple.kind != TypeKind.Tuple) {
			failures += keyword + ": lost tuple default; ";
		} else {
			assert tuple.typeChildren[0] == params[0], keyword;
			assert peelToRepr(tuple.typeChildren[1])!.kind == TypeKind.String;
		}
	}
	assert failures == "", failures;
}
