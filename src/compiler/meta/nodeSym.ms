import { Symbol, SymbolKind } from "../../ast/node";

export function isMetaNodeSym(sym: Symbol | null): boolean {
	return sym != null && sym.symbolKind == SymbolKind.Class && sym.name == "Node" && sym.modulePath.endsWith("/std/meta/node.ms");
}

import { makeSymbol } from "../../checker/symbol";

function nodeSymIn(path: string, kind: SymbolKind): Symbol {
	const sym = makeSymbol("Node", kind, null, false);
	sym.modulePath = path;
	return sym;
}

test "the macro Node is the class declared in std/meta/node, not any class spelled Node" {
	assert isMetaNodeSym(nodeSymIn("/repo/std/meta/node.ms", SymbolKind.Class));
	assert !isMetaNodeSym(nodeSymIn("/repo/src/app/tree.ms", SymbolKind.Class));
	assert !isMetaNodeSym(nodeSymIn("/repo/std/meta/node.ms", SymbolKind.Function));
	assert !isMetaNodeSym(null);
}
