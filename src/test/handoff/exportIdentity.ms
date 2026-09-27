import { CheckerContext, ExtensionRegistry, buildExportInfo, createExportRegistry, findExportsByName, registerModuleExports } from "../../checker/context";
import { makeSymbol } from "../../checker/symbol";
import { createNodeAt, NodeKind, SymbolKind, makeLoc, Symbol } from "../../ast/node";
import { inferredType } from "../../checker/types";

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
