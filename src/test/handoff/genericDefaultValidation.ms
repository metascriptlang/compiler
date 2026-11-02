import { NodeKind, ProgramData, SymbolKind, TypeKind } from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import { createContext } from "../../checker/context";
import { defineTypeParams } from "../../checker/resolvePass";
import { makeSymbol } from "../../checker/symbol";
import { unknownType } from "../../checker/types";
import { lookupSymbol } from "../../checker/symbol";
import { hasGenericParams, copyTypeShallow, emptyType, assignType } from "../../checker/types";
import { cloneNodeForCheck } from "../../monomorphize/clone";
import { hasError, checkSource } from "./helpers";

test "generic defaults reject self and forward parameter references" {
	assert hasError("type Self<T = T> = T;", "previously declared");
	assert hasError("type Forward<T = U, U = string> = T;", "previously declared");
}

test "generic defaults reject self and forward references inside tuples" {
	assert hasError("type Self<T = [T]> = T;", "previously declared");
	assert hasError("type Forward<T = [U], U = string> = T;", "previously declared");
}

test "tuple defaults retain an earlier parameter identity" {
	const ctx = checkSource("type Earlier<T, U = [T]> = U;");
	assert ctx != null && ctx.errors.length == 0;
	const sym = lookupSymbol(ctx.table, "Earlier")!;
	const value = sym.typeParams[1].typeParamDefault;
	assert value != null;
	assert value.typeChildren[0] == sym.typeParams[0];
}

test "generic defaults reject written references erased by type operators" {
	assert hasError("type Self<T = keyof { field: T }> = T;", "previously declared");
	assert hasError("type Forward<T = keyof { field: U }, U = string> = T;", "previously declared");
}

test "generic defaults respect local infer and mapped parameter identities" {
	const inferred = checkSource("type Shadow<T = string extends infer T ? T : never> = T;");
	assert inferred != null && inferred.errors.length == 0;
	const mapped = checkSource('type Shadow<T = { [T in "key"]: T }> = T;');
	assert mapped != null && mapped.errors.length == 0;
}

test "generic default reference guard resumes after nested lazy resolution" {
	assert hasError("type Outer<T = [Lazy<string>, T]> = T; type Lazy<V = string> = V;", "previously declared");
	const valid = checkSource("type Outer<T = [Lazy<string>]> = T; type Lazy<V = string> = V;");
	assert valid != null && valid.errors.length == 0;
}

test "checking default clones preserves parse metadata and independent identities" {
	const parsed = parseSource("type Pair<T = string, U = T> = U;");
	assert parsed.ok;
	const source = (parsed.value.data as ProgramData).programStmts[0];
	assert source.kind == NodeKind.TypeAliasDecl;
	const first = cloneNodeForCheck(source);
	const second = cloneNodeForCheck(source);
	const firstSym = makeSymbol("Pair", SymbolKind.TypeAlias, unknownType(), false);
	firstSym.declNode = first;
	const firstContext = createContext();
	defineTypeParams(firstContext, firstSym, "T,U");
	assert firstContext.errors.length == 0;
	const firstDefault = first.genericDefaults![1];
	assert firstDefault != null;
	assert firstDefault.nodeType == firstSym.typeParams[0];
	const secondSym = makeSymbol("Pair", SymbolKind.TypeAlias, unknownType(), false);
	secondSym.declNode = second;
	const secondContext = createContext();
	defineTypeParams(secondContext, secondSym, "T,U");
	assert secondContext.errors.length == 0;
	const secondDefault = second.genericDefaults![1];
	assert secondDefault != null;
	assert secondDefault.nodeType == secondSym.typeParams[0];
	assert firstSym.typeParams[0] != secondSym.typeParams[0];
	assert firstDefault.nodeType == firstSym.typeParams[0];
	const originalDefault = source.genericDefaults![1];
	assert originalDefault != null;
	assert originalDefault.nodeType == null;
	assert originalDefault.typeExpr!.resolvedSym == null;
}

test "generic defaults reject required parameters after defaults" {
	assert hasError("interface Pair<T = string, U> { value: U; }", "Required type parameters");
}

test "generic defaults must satisfy their constraint" {
	assert hasError("type Bad<T extends string = int32> = T;", "does not satisfy");
}

test "generic defaults retain concrete and earlier parameter checked types" {
	for (const keyword of ["type", "interface", "class", "struct"]) {
		const body = keyword == "type" ? " = U;" : " {}";
		const ctx = checkSource(keyword + " Defaults<T extends string = string, U = T[]>" + body);
		assert ctx != null;
		assert ctx.errors.length == 0;
		const sym = lookupSymbol(ctx.table, "Defaults");
		assert sym != null;
		assert sym.typeParams.length == 2;
		const first = sym.typeParams[0];
		assert first.typeParamDefault != null;
		assert first.typeParamDefault!.kind == TypeKind.String;
		const second = sym.typeParams[1].typeParamDefault;
		assert second != null;
		assert hasGenericParams(second);
		assert copyTypeShallow(first).typeParamDefault == first.typeParamDefault;
		const copied = emptyType();
		assignType(copied, first);
		assert copied.typeParamDefault == first.typeParamDefault;
		const cloned = cloneNodeForCheck(sym.declNode!);
		assert cloned.genericDefaults != null && cloned.genericDefaults!.length == 2;
	}
}

test "generic defaults preserve the identity of an earlier parameter" {
	const ctx = checkSource("type Pair<T = string, U = T> = U;");
	assert ctx.errors.length == 0;
	const sym = lookupSymbol(ctx.table, "Pair")!;
	assert sym.typeParams[1].typeParamDefault == sym.typeParams[0];
}


test "generic default constraints follow only a source parameter bound" {
	const ctx = checkSource("type Good<T extends string, U extends string = T> = U;");
	assert ctx.errors.length == 0;
	assert hasError("type Bad<T, U extends string = T> = U;", "does not satisfy");
	assert hasError("type Bad<T extends string, U extends T = string> = U;", "does not satisfy");
	const identity = checkSource("type Good<T, U extends T = T> = U;");
	assert identity.errors.length == 0;
}

test "compound generic default constraints fail explicitly rather than pass unchecked" {
	assert hasError("type Pending<T, U extends T[] = string[]> = U;", "compound generic-dependent");
}
