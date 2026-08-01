// Synthesized runtime calls carry a NAME but no symbol: lowerings build
// `makeIdent("msNumberToStringRadix")` long after the checker ran. On the C
// backend those names hit extern runtime decls, but on JS the implementation is
// an ordinary exported function in the prelude — whose emitted name is
// module-qualified. Binding the name to its defining symbol here keeps the one
// naming oracle intact: decl and reference read the SAME symbol.
//
// Reference analog: getCompilerProc — synthesized calls resolve to the real
// runtime symbol rather than trusting a bare textual name to survive.

import { Node, NodeKind, IdentifierData, Symbol, SymbolState } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { ExportedSymInfo } from "../../checker/context";
import { makeSymbolState } from "../../checker/symbol";

let _ctx: TransformContext = null as unknown as TransformContext;

export function resolveRuntimeIdents(program: Node, ctx: TransformContext): Node {
	if (ctx.checkerCtx === null) return program;
	_ctx = ctx;
	walkNode(program, bindSynthesizedIdent);
	_ctx = null as unknown as TransformContext;
	return program;
}

function bindSynthesizedIdent(node: Node): Node {
	if (node.kind !== NodeKind.Identifier) return node;
	if (node.resolvedSym !== null) return node;
	const d = node.data as IdentifierData;
	const info = lookupRuntimeExport(d.name);
	if (info === null) return node;
	node.resolvedSym = runtimeSymOf(info);
	return node;
}

// Only the fields the JS naming oracle reads — a runtime routine is never
// generic, overloaded or default-argumented, so the wider import-path symbol
// construction would carry nothing this node can use.
function runtimeSymOf(info: ExportedSymInfo): Symbol {
	const sym = makeSymbolState(info.name, info.kind, info.symType, false, SymbolState.Shaped);
	sym.modulePath = info.definingModule;
	if (info.originalName !== "") sym.originalName = info.originalName;
	if (info.nativeName !== "") sym.nativeName = info.nativeName;
	return sym;
}

// An unresolved name may match exports from several modules; a runtime routine
// always lives in the prelude, so that entry wins. Anything ambiguous is left
// alone — emitting the bare name keeps the previous behaviour instead of
// silently binding to an unrelated module's export.
function lookupRuntimeExport(name: string): ExportedSymInfo {
	const hits = _ctx.checkerCtx.exportRegistry.nameIndex.get(name);
	if (hits === null || hits.length === 0) return null as unknown as ExportedSymInfo;
	if (hits.length === 1) return hits[0];
	for (const info of hits) {
		if (info.definingModule.indexOf("std/core/") >= 0) return info;
	}
	return null as unknown as ExportedSymInfo;
}
