// bug028 — Preserving Interface/TypeAlias/Class/Actor declNode in
//          buildExportInfo polluted importer-side type resolution.
//
// Symptom:  After widening `buildExportInfo` (src/checker/context.ms) to
//           also preserve InterfaceDecl/TypeAliasDecl/ClassDecl/ActorDecl
//           in `exportInfo.declNode`, `bun run-ms run src/index.ms` emitted
//           30+ type errors like:
//             "Type 'JsonValueData.Null | ... | JsonValueData.Int' is not
//              assignable to type 'SourceLocation' for field 'location'"
//           on `const info: ExportedSymInfo = { location: ..., kind: ... }`
//           literals in src/checker/orchestrator.ms — code that has nothing
//           to do with JsonValueData.
//
// Root cause: When `exportInfo.declNode` is propagated to the importing
//           module's `sym.declNode` (via collectPass.importSymFromRegistry
//           and checkExprPass.createSymFromExport), the subsequent
//           `ensureShaped` call dispatches on `sym.declNode.kind`:
//             InterfaceDecl → resolveInterface (re-resolves in importer scope)
//             ClassDecl     → resolveClass     (walks class body, resolves
//                                               every method's param/return
//                                               types — including references
//                                               to OTHER cross-module DUs
//                                               like JsonValueData)
//             TypeAliasDecl → resolveTypeAlias (re-resolves match-type DU)
//             ActorDecl     → resolveActor     (same as resolveClass)
//           These re-resolutions populate the importer's type registry with
//           foreign Type entries, after which the checker's structural-DU
//           candidate matcher considers them as candidates for ANY object
//           literal in the importer with overlapping field shapes.
//
// Fix:      In `buildExportInfo`, preserve `declNode` only for the kinds
//           that downstream consumers can safely process in the importer
//           module:
//             - FunctionDecl (any) — `resolveFunction` is self-contained
//               and Phase 8b's @comptime walker needs the body AST.
//             - Static generic MethodDecl — for cross-module mono.
//             - EnumDecl — `ensureShaped` has NO EnumDecl handler, so the
//               match falls to `_ => {}` (no-op). Phase 8c walker injects
//               the enum decl directly into the synthetic @comptime program.
//           For InterfaceDecl / TypeAliasDecl that the Phase 8c walker
//           still needs, it reads them via the Type.sym chain
//           (`expInfo.symType.sym.declNode`) — bridging back to the
//           defining module's symbol without setting the importer's
//           sym.declNode.
//
// Verification: `bun run-ms run src/index.ms` drops back to the project's
//           baseline (3 unrelated type errors in anh's WIP), `bun run-ms run`
//           on a fixture using cross-module `readFile` inside `@comptime`
//           still folds correctly, AND `JsonValueData` no longer appears
//           in type-error output.

import { CheckerContext, ExportRegistry, createExportRegistry, registerModuleExports, ModuleExports, ExportedSymInfo, findExportsByName, buildExportInfo } from "../../checker/context";
import { makeSymbol } from "../../checker/symbol";
import { createNodeAt, NodeKind, SymbolKind, Type, TypeKind, makeLoc, Symbol } from "../../ast/node";
import { unknownType } from "../../checker/types";

// Helper: build a minimal sym + decl pair and run buildExportInfo on it.
function _buildExportFor(name: string, declKind: int32): ExportedSymInfo {
	const zl = makeLoc(0, 0);
	const sym = makeSymbol(name, SymbolKind.TypeAlias, unknownType(), false);
	if (declKind === NodeKind.InterfaceDecl) {
		sym.declNode = createNodeAt(NodeKind.InterfaceDecl, {
			interfaceName: name, interfaceFields: [], fieldTypes: [],
			interfaceFlags: "", interfaceBaseName: "", nameLocation: zl,
			fieldLocations: [],
		}, zl);
	} else if (declKind === NodeKind.TypeAliasDecl) {
		sym.declNode = createNodeAt(NodeKind.TypeAliasDecl, {
			aliasName: name, aliasType: "", aliasGenericParams: "",
			discriminantName: "", discriminantType: "", variants: [],
			nameLocation: zl,
		}, zl);
	} else if (declKind === NodeKind.ClassDecl) {
		sym.declNode = createNodeAt(NodeKind.ClassDecl, {
			className: name, classBody: [], classFlags: "", classBaseName: "",
			classGenericParams: "", nameLocation: zl,
		}, zl);
	} else if (declKind === NodeKind.ActorDecl) {
		sym.declNode = createNodeAt(NodeKind.ActorDecl, {
			actorName: name, actorBody: [], actorFlags: "", nameLocation: zl,
		}, zl);
	} else if (declKind === NodeKind.EnumDecl) {
		sym.declNode = createNodeAt(NodeKind.EnumDecl, {
			enumName: name, members: [], values: [], explicitValues: [],
			memberLocations: [], nameLocation: zl,
		}, zl);
	}
	return buildExportInfo(sym, null as unknown as ExportRegistry, "test.ms", null as unknown as CheckerContext);
}

test "bug028: buildExportInfo does NOT preserve InterfaceDecl in exportInfo.declNode" {
	const info = _buildExportFor("Foo", NodeKind.InterfaceDecl);
	assert info.declNode === null;
}

test "bug028: buildExportInfo does NOT preserve TypeAliasDecl in exportInfo.declNode" {
	const info = _buildExportFor("Bar", NodeKind.TypeAliasDecl);
	assert info.declNode === null;
}

test "bug028: buildExportInfo does NOT preserve ClassDecl in exportInfo.declNode" {
	const info = _buildExportFor("Baz", NodeKind.ClassDecl);
	assert info.declNode === null;
}

test "bug028: buildExportInfo does NOT preserve ActorDecl in exportInfo.declNode" {
	const info = _buildExportFor("Qux", NodeKind.ActorDecl);
	assert info.declNode === null;
}

test "bug028: buildExportInfo DOES preserve EnumDecl in exportInfo.declNode" {
	// Safe because ensureShaped has no EnumDecl handler — falls to `_ => {}`.
	const info = _buildExportFor("Color", NodeKind.EnumDecl);
	assert info.declNode !== null;
	assert info.declNode.kind === NodeKind.EnumDecl;
}
