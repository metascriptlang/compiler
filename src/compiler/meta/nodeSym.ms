import { Symbol, SymbolKind } from "../../ast/node";

export function isMetaNodeSym(sym: Symbol | null): boolean {
	return sym != null && sym.symbolKind == SymbolKind.Class && sym.builtinKind == "MetaNode";
}

import { makeSymbol } from "../../checker/symbol";

function nodeSymIn(builtinKind: string, kind: SymbolKind): Symbol {
	const sym = makeSymbol("Node", kind, null, false);
	sym.builtinKind = builtinKind;
	return sym;
}

test "the macro Node is the class std/meta tags as MetaNode, not any class spelled Node" {
	assert isMetaNodeSym(nodeSymIn("MetaNode", SymbolKind.Class));
	assert !isMetaNodeSym(nodeSymIn("", SymbolKind.Class));
	assert !isMetaNodeSym(nodeSymIn("MetaNode", SymbolKind.Function));
	assert !isMetaNodeSym(null);
}
