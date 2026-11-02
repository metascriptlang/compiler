import {
	Node, ProgramData, SymbolKind, TypeObjectData, TypeArrayData, IdentifierData,
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import {
	cloneNodeForCheck, cloneNodeKeepSem, monoCloneNode,
} from "../../monomorphize/clone";
import { stringType } from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";

function parsedDefaultDeclaration(): Node {
	const parsed = parseSource("type Pair<T, U = { items: T[] }> = U;");
	if (!parsed.ok) throw new Error(parsed.error);
	return (parsed.value.data as ProgramData).programStmts[0];
}

test "check clones isolate generic default arrays and nullable wrappers" {
	const source = parsedDefaultDeclaration();
	const first = cloneNodeForCheck(source);
	const second = cloneNodeForCheck(source);
	const original = source.genericDefaults!;
	const a = first.genericDefaults!;
	const b = second.genericDefaults!;
	assert a != original && b != original && a != b;
	assert a.length == 2 && a[0] == null && b[0] == null;
	assert a[1] != original[1] && b[1] != original[1] && a[1] != b[1];
	const annotation = a[1];
	const originalAnnotation = original[1];
	const secondAnnotation = b[1];
	assert annotation != null && originalAnnotation != null;
	assert secondAnnotation != null;
	annotation.nodeType = stringType();
	assert originalAnnotation.nodeType == null;
	assert secondAnnotation.nodeType == null;
}

test "check clones isolate nested positioned generic default types" {
	const source = parsedDefaultDeclaration();
	const first = cloneNodeForCheck(source);
	const second = cloneNodeForCheck(source);
	const originalAnnotation = source.genericDefaults![1];
	const firstAnnotation = first.genericDefaults![1];
	const secondAnnotation = second.genericDefaults![1];
	assert originalAnnotation != null && firstAnnotation != null;
	assert secondAnnotation != null;
	const original = originalAnnotation.typeExpr!;
	const a = firstAnnotation.typeExpr!;
	const b = secondAnnotation.typeExpr!;
	assert a != original && b != original && a != b;
	const originalArray = (original.data as TypeObjectData).typExprFieldTypes[0];
	const aArray = (a.data as TypeObjectData).typExprFieldTypes[0];
	const bArray = (b.data as TypeObjectData).typExprFieldTypes[0];
	assert aArray != originalArray && aArray != bArray;
	const originalName = (originalArray.data as TypeArrayData).typExprElement!;
	const aName = (aArray.data as TypeArrayData).typExprElement!;
	const bName = (bArray.data as TypeArrayData).typExprElement!;
	assert aName != originalName && aName != bName;
	aName.data = { name: "changed" };
	aName.resolvedSym = makeSymbol("changed", SymbolKind.TypeAlias, stringType(), false);
	assert originalName.resolvedSym == null && bName.resolvedSym == null;
	assert (originalName.data as IdentifierData).name == "T";
	assert (bName.data as IdentifierData).name == "T";
}

test "check clones preserve a default with no positioned type expression" {
	const source = parsedDefaultDeclaration();
	const annotation = source.genericDefaults![1];
	assert annotation != null;
	annotation.typeExpr = null;
	annotation.nodeType = stringType();
	const cloned = cloneNodeForCheck(source);
	const clonedAnnotation = cloned.genericDefaults![1];
	assert clonedAnnotation != null && clonedAnnotation != annotation;
	assert clonedAnnotation.typeExpr == null;
	assert clonedAnnotation.nodeType == null;
	assert annotation.nodeType != null;
}

test "clone modes preserve absent defaults and existing semantic sharing" {
	const source = parsedDefaultDeclaration();
	assert monoCloneNode(source).genericDefaults == source.genericDefaults;
	assert cloneNodeKeepSem(source).genericDefaults == source.genericDefaults;
	source.genericDefaults = null;
	assert cloneNodeForCheck(source).genericDefaults == null;
}
