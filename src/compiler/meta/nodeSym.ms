import { Symbol, SymbolKind } from "../../ast/node";
import { resolveRuntimeDir } from "../../utils/path";

export function isMetaNodeSym(sym: Symbol | null): boolean {
	return sym != null && sym.symbolKind == SymbolKind.Class && sym.builtinKind == "MetaNode";
}

let _metaNodeModule = "";

// The std/meta node module the running compiler loads from beside itself.
export function metaNodeModulePath(): string {
	if (_metaNodeModule == "") _metaNodeModule = resolveRuntimeDir() + "/std/meta/node.ms";
	return _metaNodeModule;
}

// A class or interface declared in the macro module: the host builds its objects to the wire shape,
// which differs from the declared one, so a macro reads their fields by name.
export function isMetaWireSym(sym: Symbol | null): boolean {
	return sym != null && (isMetaNodeSym(sym) || ((sym.symbolKind == SymbolKind.Class || sym.symbolKind == SymbolKind.Interface) && sym.modulePath == metaNodeModulePath()));
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

test "a class of the macro module is a wire class, one of another module is not" {
	const inMeta = nodeSymIn("", SymbolKind.Class);
	inMeta.modulePath = metaNodeModulePath();
	assert isMetaWireSym(inMeta);
	const lookalike = nodeSymIn("", SymbolKind.Class);
	lookalike.modulePath = "/app/std/meta/node.ms";
	assert !isMetaWireSym(lookalike);
	const iface = nodeSymIn("", SymbolKind.Interface);
	iface.modulePath = metaNodeModulePath();
	assert isMetaWireSym(iface);
	iface.symbolKind = SymbolKind.Function;
	assert !isMetaWireSym(iface);
	assert !isMetaWireSym(nodeSymIn("", SymbolKind.Class));
	assert !isMetaWireSym(null);
}
