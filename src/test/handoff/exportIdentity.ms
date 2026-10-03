import { CheckerContext, ExtensionRegistry, buildExportInfo, createExportRegistry, findExportsByName, registerModuleExports } from "../../checker/context";
import { makeSymbol } from "../../checker/symbol";
import { createNodeAt, NodeKind, SymbolKind, makeLoc, Symbol } from "../../ast/node";
import { inferredType } from "../../checker/types";
import { compileProjectToC, compileProjectToJS, MapEntry } from "../helpers";

function declaringSymbol(name: string, kind: NodeKind): Result<Symbol, string> {
	const loc = makeLoc(0, 0);
	const sym = makeSymbol(name, SymbolKind.TypeAlias, inferredType(), false);
	if (kind == NodeKind.InterfaceDecl) {
		sym.declNode = createNodeAt(NodeKind.InterfaceDecl, { interfaceName: name, interfaceFields: [], nameLocation: loc }, loc);
	} else if (kind == NodeKind.TypeAliasDecl) {
		sym.declNode = createNodeAt(NodeKind.TypeAliasDecl, { aliasName: name, aliasType: "", aliasGenericParams: "", discriminantName: "", discriminantType: "", nameLocation: loc }, loc);
	} else if (kind == NodeKind.ClassDecl) {
		sym.declNode = createNodeAt(NodeKind.ClassDecl, { className: name, classBody: [], nameLocation: loc }, loc);
	} else if (kind == NodeKind.ActorDecl) {
		sym.declNode = createNodeAt(NodeKind.ActorDecl, { actorName: name, actorBody: [], nameLocation: loc }, loc);
	} else if (kind == NodeKind.EnumDecl) {
		sym.declNode = createNodeAt(NodeKind.EnumDecl, { enumName: name, memberLocations: [], nameLocation: loc }, loc);
	} else {
		return Result.err("unsupported declaration kind in export identity matrix: " + kind.toString());
	}
	return Result.ok(sym);
}

test "export identity: same-named declarations in different modules remain distinct" {
	const kinds = [NodeKind.InterfaceDecl, NodeKind.TypeAliasDecl, NodeKind.ClassDecl, NodeKind.ActorDecl, NodeKind.EnumDecl];
	for (const kind of kinds) {
		const leftResult = declaringSymbol("Shared", kind);
		const rightResult = declaringSymbol("Shared", kind);
		assert leftResult.ok;
		assert rightResult.ok;
		const left = leftResult.value;
		const right = rightResult.value;
		const registry = createExportRegistry();
		const leftInfo = buildExportInfo(left, null as unknown as ExtensionRegistry, "left.ms", null as unknown as CheckerContext);
		const rightInfo = buildExportInfo(right, null as unknown as ExtensionRegistry, "right.ms", null as unknown as CheckerContext);
		registerModuleExports(registry, "left.ms", [leftInfo]);
		registerModuleExports(registry, "right.ms", [rightInfo]);
		const found = findExportsByName(registry, "Shared");
		assert found.length == 2, kind.toString();
		assert found[0].sym == left, kind.toString();
		assert found[1].sym == right, kind.toString();
		assert found[0].sym != found[1].sym, kind.toString();
		assert found[0].sym.declNode.kind == kind;
		assert found[1].sym.declNode.kind == kind;
	}
}

test "export identity: an exported alias does not rename or clone the defining symbol" {
	const kinds = [NodeKind.InterfaceDecl, NodeKind.TypeAliasDecl, NodeKind.ClassDecl, NodeKind.ActorDecl, NodeKind.EnumDecl];
	for (const kind of kinds) {
		const result = declaringSymbol("Original", kind);
		assert result.ok;
		const original = result.value;
		const registry = createExportRegistry();
		const aliased = buildExportInfo(original, null as unknown as ExtensionRegistry, "owner.ms", null as unknown as CheckerContext, "PublicAlias");
		registerModuleExports(registry, "owner.ms", [aliased]);
		const found = findExportsByName(registry, "PublicAlias");
		assert found.length == 1, kind.toString();
		assert found[0].sym == original;
		assert original.name == "Original";
		assert original.declNode.kind == kind;
		assert findExportsByName(registry, "Original").length == 0;
	}
}

const IDENTITY_LIB_PATH = "test/exportIdentity/lib.ms";
const IDENTITY_MAIN_PATH = "test/exportIdentity/main.ms";

function identityEntries(libSource: string, mainSource: string): MapEntry[] {
	return [
		{ entryPath: IDENTITY_LIB_PATH, entrySource: libSource },
		{ entryPath: IDENTITY_MAIN_PATH, entrySource: mainSource },
	];
}

function refusedInMain(libSource: string, mainSource: string): boolean {
	const cCode = compileProjectToC(identityEntries(libSource, mainSource), IDENTITY_MAIN_PATH);
	return cCode.startsWith("ERROR: check [") && cCode.contains("main.ms]");
}

function fitsOnBothBackends(libSource: string, mainSource: string): boolean {
	const cCode = compileProjectToC(identityEntries(libSource, mainSource), IDENTITY_MAIN_PATH);
	const jsCode = compileProjectToJS(identityEntries(libSource, mainSource), IDENTITY_MAIN_PATH);
	return !cCode.startsWith("ERROR") && !jsCode.startsWith("ERROR");
}

test "export identity: fit follows the declaration of a generic or enum, not its name" {
	const cases = [
		{
			name: "a generic class with other fields",
			libSource: `export class Box<T> { v: T; constructor(v: T) { this.v = v; } }\n` +
				`export function mkA(): Box<string> { return new Box<string>("a"); }\n`,
			redeclared: `import { mkA } from "./lib";\n` +
				`class Box<T> { n: int32; w: T; ` +
				`constructor(w: T) { this.n = 7; this.w = w; } }\n` +
				`const m: Box<string> = mkA();\nconsole.log(m.w);\n`,
			imported: `import { Box, mkA } from "./lib";\n` +
				`const m: Box<string> = mkA();\n` +
				`const n: Box<string> = new Box<string>("b");\n` +
				`console.log(m.v, n.v);\n`,
		},
		{
			name: "a generic interface with other fields",
			libSource: `export interface Box<T> { v: T; }\n` +
				`export function mkA(): Box<string> { return { v: "a" }; }\n`,
			redeclared: `import { mkA } from "./lib";\n` +
				`interface Box<T> { n: int32; w: T; }\n` +
				`const m: Box<string> = mkA();\nconsole.log(m.w);\n`,
			imported: `import { Box, mkA } from "./lib";\n` +
				`const m: Box<string> = mkA();\nconsole.log(m.v);\n`,
		},
		{
			name: "a generic alias with other fields, met as an argument",
			libSource: `export type Box<T> = { v: T };\n` +
				`export function mkA(): Box<string> { return { v: "a" }; }\n`,
			redeclared: `import { mkA } from "./lib";\n` +
				`type Box<T> = { n: int32, w: T };\n` +
				`function show(b: Box<string>): string { return b.w; }\n` +
				`console.log(show(mkA()));\n`,
			imported: `import { Box, mkA } from "./lib";\n` +
				`function show(b: Box<string>): string { return b.v; }\n` +
				`console.log(show(mkA()));\n`,
		},
		{
			name: "an enum with other members",
			libSource: `export enum K { A, B, C }\n` +
				`export function mkA(): K { return K.C; }\n`,
			redeclared: `import { mkA } from "./lib";\n` +
				`enum K { X, Y }\n` +
				`const m: K = mkA();\nconsole.log(m == K.X);\n`,
			imported: `import { K, mkA } from "./lib";\n` +
				`const m: K = mkA();\nconsole.log(m == K.C);\n`,
		},
	];
	for (const item of cases) {
		assert fitsOnBothBackends(item.libSource, item.imported), item.name + ": imported";
		assert refusedInMain(item.libSource, item.redeclared), item.name + ": redeclared";
	}
}

test "export identity: a same-shaped generic interface of another module fits structurally" {
	const libSource = `export interface Box<T> { v: T; }\n` +
		`export function mkA(): Box<string> { return { v: "a" }; }\n`;
	const mainSource = `import { mkA } from "./lib";\n` +
		`interface Box<T> { v: T; }\n` +
		`const m: Box<string> = mkA();\nconsole.log(m.v);\n`;
	assert fitsOnBothBackends(libSource, mainSource);
}
