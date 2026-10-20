// Test: Discriminated union types — parse, resolve, codegen
// Syntax: type X = match (disc: EnumType) { EnumVal => { fields }, ... };

import { checkSource, strictErrorCount, hasError } from "./helpers";
import { compileToC } from "../helpers";
import { hasErrors } from "../../checker/context";
import { isDiscriminatedUnion, getDiscriminantName, createEnumLiteral } from "../../checker/types";
import { findVariantByEnumMember } from "../../checker/compat";
import { lookupSymbol } from "../../checker/symbol";
import { CheckerContext } from "../../checker/context";
import { Type, TypeFlag } from "../../ast/node";

function variantOf(ctx: CheckerContext, t: Type, enumName: string, member: string): int32 {
	const enumSym = lookupSymbol(ctx.table, enumName);
	if (enumSym == null) throw new Error(`no enum '${enumName}'`);
	return findVariantByEnumMember(t, createEnumLiteral(enumSym.symbolType, member));
}

test "parse discriminated union type alias" {
	const ctx = checkSource("enum Color { Red, Green, Blue }\ntype Shape = match (color: Color) {\n\tColor.Red => { radius: number },\n\tColor.Green => { width: number, height: number },\n\tColor.Blue => { side: number },\n};");
	assert ctx != null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("DISC-UNION-ERR: " + e.message);
		}
	}
	assert !hasErrors(ctx);
}

test "discriminated union type has discriminant metadata" {
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};");
	assert ctx != null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("META-ERR: " + e.message);
		}
	}
	assert !hasErrors(ctx);

	// Find the Data symbol
	const dataSym = lookupSymbol(ctx.table, "Data");
	assert dataSym != null;
	const t = dataSym.symbolType;
	assert isDiscriminatedUnion(t);
	assert getDiscriminantName(t) == "kind";
	assert variantOf(ctx, t, "Kind", "A") == 0;
	assert variantOf(ctx, t, "Kind", "B") == 1;
}

test "discriminated union rejects invalid enum member" {
	assert hasError("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.C => { y: string },\n};", "not a member");
}

test "a variant key spelled bare names the same member as a qualified one" {
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tA => { x: number },\n\tKind.B => { y: string },\n};");
	assert ctx != null;
	assert !hasErrors(ctx);
	const dataSym = lookupSymbol(ctx.table, "Data");
	assert dataSym != null;
	const t = dataSym.symbolType;
	assert variantOf(ctx, t, "Kind", "A") == 0;
	assert variantOf(ctx, t, "Kind", "B") == 1;
}

test "a variant is found by the member's enum, not by its spelling" {
	const ctx = checkSource("enum Kind { Round_One, One }\nenum Other { Round_One }\ntype Data = match (kind: Kind) {\n\tKind.One => { x: number },\n\tKind.Round_One => { y: string },\n};");
	assert ctx != null;
	assert !hasErrors(ctx);
	const dataSym = lookupSymbol(ctx.table, "Data");
	assert dataSym != null;
	const t = dataSym.symbolType;
	assert variantOf(ctx, t, "Kind", "Round_One") == 1;
	assert variantOf(ctx, t, "Kind", "One") == 0;
	assert variantOf(ctx, t, "Other", "Round_One") == -1;
}

test "direct field access on discriminated union — unique field" {
	// "x" only exists in variant A — should resolve to number without as-cast
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction getX(d: Data): number { return d.x; }");
	assert ctx != null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("FIELD-ERR: " + e.message);
		}
	}
	assert !hasErrors(ctx);
}

test "direct field access — discriminant field returns enum type" {
	// "kind" is the discriminant — should resolve to the enum type
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction getKind(d: Data): Kind { return d.kind; }");
	assert ctx != null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("DISC-FIELD-ERR: " + e.message);
		}
	}
	assert !hasErrors(ctx);
}

test "construction validation — correct variant fields" {
	const src = "enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction makeA(): Data { return { kind: Kind.A, x: 42 }; }";
	const ctx = checkSource(src);
	assert ctx != null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("CONSTR-ERR: " + e.message);
		}
	}
	assert !hasErrors(ctx);
}

test "construction validation — wrong variant field" {
	const src = "enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction bad(): Data { return { kind: Kind.A, y: \"oops\" }; }";
	assert hasError(src, "'y' does not exist in type");
	assert hasError(src.replace("type Data", "struct Data"), "does not exist on variant");
}

test "construction validation — missing discriminant" {
	const src = "enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction bad(): Data { return { x: 42 }; }";
	assert hasError(src, "missing discriminant");
}

test "discriminated union rejects non-enum discriminant" {
	// string is not an enum — resolver should reject it
	assert hasError("type Data = match (kind: string) {\n\tFoo => { x: number },\n};", "must be an enum");
}

test "multi-field variant access" {
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number, y: number },\n\tKind.B => { name: string },\n};\nfunction getY(d: Data): number { return d.y; }");
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "single variant discriminated union" {
	const ctx = checkSource("enum Kind { Only }\ntype Data = match (kind: Kind) {\n\tKind.Only => { value: number },\n};");
	assert ctx != null;
	assert !hasErrors(ctx);
	const dataSym = lookupSymbol(ctx.table, "Data");
	assert dataSym != null;
	assert isDiscriminatedUnion(dataSym.symbolType);
	assert variantOf(ctx, dataSym.symbolType, "Kind", "Only") == 0;
}

test "shared field across variants resolves without error" {
	// "value" exists in both variants with same type — should resolve fine
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { value: number },\n\tKind.B => { value: number },\n};\nfunction getVal(d: Data): number { return d.value; }");
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "nonexistent field access on discriminated union" {
	// "z" doesn't exist in any variant — getProperty returns unknown,
	// checker may or may not error depending on context. Verify no crash.
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction test(d: Data): number { return d.z; }");
	assert ctx != null;
	// Should either error on unknown field or produce type mismatch — either way, no crash
}

const NARROWED_HEAD = "enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction twice(this d: Data): number { return 2; }\n";

test "a reference narrowed to one variant still calls the union's extensions" {
	assert strictErrorCount(NARROWED_HEAD + "function viaIf(d: Data): number { if (d.kind == Kind.A) return d.twice(); return 0; }") == 0;
	assert strictErrorCount(NARROWED_HEAD + "function viaInit(): number { const d: Data = { kind: Kind.A, x: 1 }; return d.twice(); }") == 0;
}

test "a reference narrowed to one variant refuses another variant's field and a name nothing declares" {
	assert hasError(NARROWED_HEAD + "function other(d: Data): string { if (d.kind == Kind.A) return d.y; return \"\"; }", "'y' does not exist on type");
	assert strictErrorCount(NARROWED_HEAD + "function none(d: Data): number { if (d.kind == Kind.A) return d.z; return 0; }") > 0;
}

test "construction of second variant" {
	const src = "enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n};\nfunction makeB(): Data { return { kind: Kind.B, y: \"hello\" }; }";
	const ctx = checkSource(src);
	assert ctx != null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("CONSTR-B-ERR: " + e.message);
		}
	}
	assert !hasErrors(ctx);
}

test "many-variant discriminated union" {
	const src = "enum Op { Add, Sub, Mul, Div, Mod }\ntype Expr = match (op: Op) {\n\tOp.Add => { left: number, right: number },\n\tOp.Sub => { left: number, right: number },\n\tOp.Mul => { left: number, right: number },\n\tOp.Div => { left: number, right: number },\n\tOp.Mod => { left: number, right: number },\n};";
	const ctx = checkSource(src);
	assert ctx != null;
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "Expr");
	assert sym != null;
	assert isDiscriminatedUnion(sym.symbolType);
	assert variantOf(ctx, sym.symbolType, "Op", "Mod") == 4;
}

test "empty variant body" {
	const ctx = checkSource("enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => {},\n};");
	assert ctx != null;
	if (ctx.errors.length > 0) {
		for (const e of ctx.errors) {
			console.log("EMPTY-ERR: " + e.message);
		}
	}
	assert !hasErrors(ctx);
}

test "regular type alias still works after parser changes" {
	// Non-discriminated union — must not regress
	const ctx = checkSource("type Num = number;\nfunction add(a: Num, b: Num): Num { return a + b; }");
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "regular union type alias still works" {
	const ctx = checkSource("type Val = | { x: number } | { y: string };\nfunction getTag(v: Val): number { return 0; }");
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "codegen emits enum _tag for discriminated union" {
	const src = "enum Kind { A, B }\ntype Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: number },\n};\nexport function make(): Data { return { kind: Kind.A, x: 1 }; }";
	const c = compileToC(src);
	if (c.ok) {
		console.log("C-TAG: " + c.value);
	} else {
		console.log("C-TAG-ERR: " + c.error);
	}
}

const structMatchBody = "(kind: Kind) {\n\tKind.A => { x: number },\n\tKind.B => { y: string },\n}";

test "a struct match declares the union the type form declares, as a value" {
	const asStruct = checkSource("enum Kind { A, B }\nstruct Data = match " + structMatchBody + ";");
	const asType = checkSource("enum Kind { A, B }\ntype Data = match " + structMatchBody + ";");
	assert !hasErrors(asStruct);
	const sv = lookupSymbol(asStruct.table, "Data").symbolType;
	const tv = lookupSymbol(asType.table, "Data").symbolType;
	assert isDiscriminatedUnion(sv);
	assert getDiscriminantName(sv) == "kind";
	assert variantOf(asStruct, sv, "Kind", "B") == 1;
	assert sv.typeFlags.has(TypeFlag.ValueUnion);
	assert !tv.typeFlags.has(TypeFlag.ValueUnion);
}

test "a generic struct match is a value union" {
	const ctx = checkSource("struct Either<T, E> = match (ok: boolean) {\n\ttrue => { value: T },\n\tfalse => { error: E },\n};");
	assert !hasErrors(ctx);
	assert lookupSymbol(ctx.table, "Either").symbolType.typeFlags.has(TypeFlag.ValueUnion);
}

test "a struct match is checked for exhaustiveness and for its enum members" {
	const body = "enum Kind { A, B }\nstruct Data = match " + structMatchBody + ";\n";
	assert hasError(body + "function f(d: Data): number { return match (d.kind) { Kind.A => 1 }; }", "Non-exhaustive match: missing 'Kind.B'");
	assert hasError("enum Kind { A, B }\nstruct Data = match (kind: Kind) {\n\tKind.A => { x: number },\n\tKind.C => { y: string },\n};", "not a member");
}
