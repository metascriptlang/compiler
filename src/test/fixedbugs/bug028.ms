// bug028 — Preserving Interface/TypeAlias/Class/Actor declNode in
//          buildExportInfo polluted importer-side type resolution.
//
// Symptom:  After widening `buildExportInfo` (src/checker/context.ms) to
//           also preserve InterfaceDecl/TypeAliasDecl/ClassDecl/ActorDecl
//           in `exportInfo.declNode`, compiling src/index.ms emitted
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
// Fix:      An import binds the exporting module's own symbol instead of a
//           copy carrying its declNode, so no declaration is re-resolved in
//           the importer's scope. The tests pin that identity per decl kind.
//
// Verification: compiling src/index.ms drops back to the project's
//           baseline (3 unrelated type errors in anh's WIP), and a fixture
//           using cross-module `readFile` inside `@comptime`
//           still folds correctly, AND `JsonValueData` no longer appears
//           in type-error output.

import { CheckerContext, ExportRegistry, ExtensionRegistry, createExportRegistry, registerModuleExports, ModuleExports, findExportsByName, buildExportInfo } from "../../checker/context";
import { makeSymbol } from "../../checker/symbol";
import { createNodeAt, NodeKind, SymbolKind, Type, TypeKind, makeLoc, Symbol } from "../../ast/node";
import { inferredType } from "../../checker/types";

function _symFor(name: string, declKind: int32): Symbol {
	const zl = makeLoc(0, 0);
	const sym = makeSymbol(name, SymbolKind.TypeAlias, inferredType(), false);
	if (declKind == NodeKind.InterfaceDecl) {
		sym.declNode = createNodeAt(NodeKind.InterfaceDecl, {
			interfaceName: name, interfaceFields: [], nameLocation: zl,
		}, zl);
	} else if (declKind == NodeKind.TypeAliasDecl) {
		sym.declNode = createNodeAt(NodeKind.TypeAliasDecl, {
			aliasName: name, aliasType: "", aliasGenericParams: "",
			discriminantName: "", discriminantType: "",
			nameLocation: zl,
		}, zl);
	} else if (declKind == NodeKind.ClassDecl) {
		sym.declNode = createNodeAt(NodeKind.ClassDecl, {
			className: name, classBody: [], nameLocation: zl,
		}, zl);
	} else if (declKind == NodeKind.ActorDecl) {
		sym.declNode = createNodeAt(NodeKind.ActorDecl, {
			actorName: name, actorBody: [], nameLocation: zl,
		}, zl);
	} else if (declKind == NodeKind.EnumDecl) {
		sym.declNode = createNodeAt(NodeKind.EnumDecl, {
			enumName: name, memberLocations: [], nameLocation: zl,
		}, zl);
	}
	return sym;
}

function _bindsDefiningSymbol(name: string, declKind: int32): boolean {
	const sym = _symFor(name, declKind);
	const info = buildExportInfo(sym, null as unknown as ExtensionRegistry, "test.ms", null as unknown as CheckerContext);
	return info.sym == sym && info.sym.declNode.kind == declKind;
}

test "bug028: an exported InterfaceDecl is the defining symbol, not a copy" {
	assert _bindsDefiningSymbol("Foo", NodeKind.InterfaceDecl);
}

test "bug028: an exported TypeAliasDecl is the defining symbol, not a copy" {
	assert _bindsDefiningSymbol("Bar", NodeKind.TypeAliasDecl);
}

test "bug028: an exported ClassDecl is the defining symbol, not a copy" {
	assert _bindsDefiningSymbol("Baz", NodeKind.ClassDecl);
}

test "bug028: an exported ActorDecl is the defining symbol, not a copy" {
	assert _bindsDefiningSymbol("Qux", NodeKind.ActorDecl);
}

test "bug028: an exported EnumDecl is the defining symbol, not a copy" {
	assert _bindsDefiningSymbol("Color", NodeKind.EnumDecl);
}
