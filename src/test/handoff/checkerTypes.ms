// Route 1: Checker — class type structure
//
// Verifies that the checker produces the correct type representations:
// - Class = Ref<Struct> (not Struct or Ref<Ref<Struct>>)
// - Interface = plain Struct

import { TypeKind } from "../../ast/node";
import { checkSource } from "./helpers";
import { lookupSymbol } from "../../checker/symbol";
import { unwrapRef, isInterfaceType } from "../../checker/types";

test "checker: class type is Ref<Struct>" {
	const ctx = checkSource("class Foo { x: number; y: string }");
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "Foo");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Ref;
	assert sym.symbolType.typeReturn !== null;
	assert sym.symbolType.typeReturn.kind === TypeKind.Struct;
	assert sym.symbolType.typeReturn.typeName === "Foo";
}

test "checker: unwrapRef gives Struct for class" {
	const ctx = checkSource("class Foo { x: number; y: string }");
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "Foo");
	assert sym !== null;
	const inner = unwrapRef(sym.symbolType);
	assert inner.kind === TypeKind.Struct;
	assert inner.typeName === "Foo";
	assert isInterfaceType(inner);
}

test "checker: interface type is plain Struct" {
	const ctx = checkSource("interface Point { x: number; y: number }");
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "Point");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Struct;
	assert isInterfaceType(sym.symbolType);
}
