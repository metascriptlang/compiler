// cparse — Declaration parser
// Port of: ~/projects/chibicc parse.c (declaration-level subset only).
//
// Parses preprocessed tokens into top-level declarations (Obj[]).
// Skips function bodies (brace-matched), full expression parsing, and statements.

import { Token, TokenKind } from "./token";
import { Obj, ObjKind } from "./obj";
import { Diagnostic, DiagSeverity, makeDiag } from "./error";
import { TargetInfo } from "./target";
import { evalConstExpr } from "./eval";
import {
	CType, CTypeKind, CMember, makeVoid, makeBool, makeChar, makeUChar,
	makeShort, makeUShort, makeInt, makeUInt, makeLong, makeULong, makeLongLong,
	makeULongLong, makeFloat, makeDouble, makeLongDouble, makePointer, makeArray,
	makeFunc, makeEnum, makeStruct, makeUnion, makeMember,
	computeStructLayout, computeUnionLayout,
} from "./type";

export interface ParseResult {
	objs: Obj[];
	diagnostics: Diagnostic[];
}

// ===== Parse Context =====

interface VarAttr {
	isTypedef: boolean;
	isStatic: boolean;
	isExtern: boolean;
	isInline: boolean;
}

interface ParseCtx {
	tok: Token;
	target: TargetInfo;
	diags: Diagnostic[];
	objs: Obj[];
	// Scope: typedef names and struct/union/enum tags
	typedefs: Map<string, CType>;
	tags: Map<string, CType>;
	// Enum constant values for const expr evaluation (e.g., B = A | 2)
	enumConstants: Map<string, int64>;
}

// ===== Token Consumption Helpers =====

function eq(ctx: ParseCtx, s: string): boolean {
	if (ctx.tok === null) return false;
	return ctx.tok.stringVal === s;
}

function advance(ctx: ParseCtx): void {
	if (ctx.tok === null) return;
	if (ctx.tok.kind !== TokenKind.Eof) {
		const next = ctx.tok.next;
		if (next === null) return; // guard: dangling end
		ctx.tok = next;
	}
}

function expect(ctx: ParseCtx, s: string): void {
	if (ctx.tok === null) return;
	if (ctx.tok.stringVal !== s) {
		ctx.diags.push(makeDiag(DiagSeverity.Error, ctx.tok.file, ctx.tok.line, ctx.tok.col,
			`expected '${s}', got '${ctx.tok.stringVal}'`));
		return;
	}
	advance(ctx);
}

function consume(ctx: ParseCtx, s: string): boolean {
	if (ctx.tok === null) return false;
	if (ctx.tok.stringVal === s) {
		advance(ctx);
		return true;
	}
	return false;
}

function isEnd(ctx: ParseCtx): boolean {
	if (ctx.tok === null) return true;
	return ctx.tok.kind === TokenKind.Eof;
}

// ===== Is Typename =====

function isTypename(ctx: ParseCtx): boolean {
	if (ctx.tok === null) return false;
	const s = ctx.tok.stringVal;
	if (ctx.tok.kind !== TokenKind.Keyword && ctx.tok.kind !== TokenKind.Ident) return false;
	return s === "void" || s === "char" || s === "short" || s === "int" || s === "long" ||
		s === "float" || s === "double" || s === "signed" || s === "unsigned" ||
		s === "_Bool" || s === "struct" || s === "union" || s === "enum" ||
		s === "typedef" || s === "static" || s === "extern" || s === "inline" ||
		s === "const" || s === "volatile" || s === "auto" || s === "register" ||
		s === "restrict" || s === "__restrict" || s === "__restrict__" || s === "_Noreturn" ||
		s === "_Atomic" || s === "_Alignas" || s === "_Thread_local" || s === "__thread" ||
		s === "__attribute__" ||
		ctx.typedefs.has(s);
}

function newVarAttr(): VarAttr {
	return { isTypedef: false, isStatic: false, isExtern: false, isInline: false };
}

// ===== declspec: Declaration Specifiers =====
// Builds the base type from keywords + struct/union/enum/typedef.

const SPEC_VOID = 1;
const SPEC_BOOL = 4;
const SPEC_CHAR = 16;
const SPEC_SHORT = 64;
const SPEC_INT = 256;
const SPEC_LONG = 1024;
const SPEC_FLOAT = 4096;
const SPEC_DOUBLE = 16384;
const SPEC_OTHER = 65536;
const SPEC_SIGNED = 131072;
const SPEC_UNSIGNED = 262144;

function declspec(ctx: ParseCtx, attr: VarAttr): CType {
	let ty = makeInt(ctx.target);
	let counter = 0;

	while (isTypename(ctx)) {
		const s = ctx.tok.stringVal;

		// Storage class specifiers
		if (s === "typedef" || s === "static" || s === "extern" || s === "inline" ||
			s === "_Thread_local" || s === "__thread") {
			if (s === "typedef") attr.isTypedef = true;
			else if (s === "static") attr.isStatic = true;
			else if (s === "extern") attr.isExtern = true;
			else if (s === "inline") attr.isInline = true;
			advance(ctx);
			continue;
		}

		// Qualifiers — recognized but ignored
		if (s === "const" || s === "volatile" || s === "auto" || s === "register" ||
			s === "restrict" || s === "__restrict" || s === "__restrict__" || s === "_Noreturn") {
			advance(ctx);
			continue;
		}

		// _Atomic
		if (s === "_Atomic") {
			advance(ctx);
			if (eq(ctx, "(")) {
				advance(ctx);
				ty = typename(ctx);
				expect(ctx, ")");
			}
			continue;
		}

		// _Alignas — skip
		if (s === "_Alignas") {
			advance(ctx);
			expect(ctx, "(");
			// Skip expression or typename
			let depth = 1;
			while (!isEnd(ctx) && depth > 0) {
				if (eq(ctx, "(")) depth = depth + 1;
				if (eq(ctx, ")")) depth = depth - 1;
				if (depth > 0) advance(ctx);
			}
			if (eq(ctx, ")")) advance(ctx);
			continue;
		}

		// __attribute__ — skip
		if (s === "__attribute__") {
			skipAttribute(ctx);
			continue;
		}

		// User-defined types: struct, union, enum, typedef name
		if (s === "struct" || s === "union" || s === "enum" || ctx.typedefs.has(s)) {
			if (counter !== 0) break;

			if (s === "struct") {
				advance(ctx);
				ty = structDecl(ctx);
			} else if (s === "union") {
				advance(ctx);
				ty = unionDecl(ctx);
			} else if (s === "enum") {
				advance(ctx);
				ty = enumSpecifier(ctx);
			} else {
				ty = ctx.typedefs.get(s) as CType;
				advance(ctx);
			}
			counter = counter + SPEC_OTHER;
			continue;
		}

		// Built-in type keywords
		if (s === "void") counter = counter + SPEC_VOID;
		else if (s === "_Bool") counter = counter + SPEC_BOOL;
		else if (s === "char") counter = counter + SPEC_CHAR;
		else if (s === "short") counter = counter + SPEC_SHORT;
		else if (s === "int") counter = counter + SPEC_INT;
		else if (s === "long") counter = counter + SPEC_LONG;
		else if (s === "float") counter = counter + SPEC_FLOAT;
		else if (s === "double") counter = counter + SPEC_DOUBLE;
		else if (s === "signed") counter = counter | SPEC_SIGNED;
		else if (s === "unsigned") counter = counter | SPEC_UNSIGNED;
		else break;

		// Map counter to type (chibicc switch at parse.c:508-568)
		if (counter === SPEC_VOID) ty = makeVoid();
		else if (counter === SPEC_BOOL) ty = makeBool();
		else if (counter === SPEC_CHAR || counter === SPEC_SIGNED + SPEC_CHAR) ty = makeChar(ctx.target);
		else if (counter === SPEC_UNSIGNED + SPEC_CHAR) ty = makeUChar();
		else if (counter === SPEC_SHORT || counter === SPEC_SHORT + SPEC_INT ||
				 counter === SPEC_SIGNED + SPEC_SHORT || counter === SPEC_SIGNED + SPEC_SHORT + SPEC_INT) ty = makeShort(ctx.target);
		else if (counter === SPEC_UNSIGNED + SPEC_SHORT || counter === SPEC_UNSIGNED + SPEC_SHORT + SPEC_INT) ty = makeUShort(ctx.target);
		else if (counter === SPEC_INT || counter === SPEC_SIGNED || counter === SPEC_SIGNED + SPEC_INT) ty = makeInt(ctx.target);
		else if (counter === SPEC_UNSIGNED || counter === SPEC_UNSIGNED + SPEC_INT) ty = makeUInt(ctx.target);
		else if (counter === SPEC_LONG || counter === SPEC_LONG + SPEC_INT ||
				 counter === SPEC_SIGNED + SPEC_LONG || counter === SPEC_SIGNED + SPEC_LONG + SPEC_INT) ty = makeLong(ctx.target);
		else if (counter === SPEC_UNSIGNED + SPEC_LONG || counter === SPEC_UNSIGNED + SPEC_LONG + SPEC_INT) ty = makeULong(ctx.target);
		else if (counter === SPEC_LONG + SPEC_LONG || counter === SPEC_LONG + SPEC_LONG + SPEC_INT ||
				 counter === SPEC_SIGNED + SPEC_LONG + SPEC_LONG || counter === SPEC_SIGNED + SPEC_LONG + SPEC_LONG + SPEC_INT) ty = makeLongLong(ctx.target);
		else if (counter === SPEC_UNSIGNED + SPEC_LONG + SPEC_LONG || counter === SPEC_UNSIGNED + SPEC_LONG + SPEC_LONG + SPEC_INT) ty = makeULongLong(ctx.target);
		else if (counter === SPEC_FLOAT) ty = makeFloat(ctx.target);
		else if (counter === SPEC_DOUBLE) ty = makeDouble(ctx.target);
		else if (counter === SPEC_LONG + SPEC_DOUBLE) ty = makeLongDouble(ctx.target);
		else {
			ctx.diags.push(makeDiag(DiagSeverity.Error, ctx.tok.file, ctx.tok.line, ctx.tok.col,
				"invalid type specifier combination"));
		}

		advance(ctx);
	}

	return ty;
}

// ===== Skip __attribute__((...)) =====

function skipAttribute(ctx: ParseCtx): void {
	advance(ctx); // skip __attribute__
	if (!eq(ctx, "(")) return;
	advance(ctx); // skip (
	if (!eq(ctx, "(")) return;
	advance(ctx); // skip (
	let depth = 2;
	while (!isEnd(ctx) && depth > 0) {
		if (eq(ctx, "(")) depth = depth + 1;
		if (eq(ctx, ")")) depth = depth - 1;
		if (depth > 0) advance(ctx);
	}
	if (eq(ctx, ")")) advance(ctx);
}

// ===== Pointers =====

function pointers(ctx: ParseCtx, ty: CType): CType {
	while (consume(ctx, "*")) {
		ty = makePointer(ctx.target, ty);
		while (eq(ctx, "const") || eq(ctx, "volatile") || eq(ctx, "restrict") ||
			   eq(ctx, "__restrict") || eq(ctx, "__restrict__")) {
			advance(ctx);
		}
	}
	return ty;
}

// ===== Type Suffix (array / function) =====

function typeSuffix(ctx: ParseCtx, ty: CType): CType {
	if (eq(ctx, "(")) {
		advance(ctx);
		return funcParams(ctx, ty);
	}
	if (eq(ctx, "[")) {
		advance(ctx);
		return arrayDimensions(ctx, ty);
	}
	return ty;
}

function funcParams(ctx: ParseCtx, returnTy: CType): CType {
	// void parameter list
	if (eq(ctx, "void") && ctx.tok.next !== null && ctx.tok.next.stringVal === ")") {
		advance(ctx); // skip void
		advance(ctx); // skip )
		return makeFunc(returnTy);
	}

	const params: CType[] = [];
	const paramNames: string[] = [];
	let isVariadic = false;

	while (!eq(ctx, ")") && !isEnd(ctx)) {
		if (params.length > 0) expect(ctx, ",");

		if (eq(ctx, "...")) {
			isVariadic = true;
			advance(ctx);
			break;
		}

		const dummyAttr = newVarAttr();
		let paramTy = declspec(ctx, dummyAttr);
		const declResult = declarator(ctx, paramTy);
		paramTy = declResult.type;
		const paramName = declResult.name;

		// Array decay to pointer (C rule)
		if (paramTy.kind === CTypeKind.Array) {
			paramTy = makePointer(ctx.target, paramTy.base);
		}
		// Function decay to pointer
		if (paramTy.kind === CTypeKind.Func) {
			paramTy = makePointer(ctx.target, paramTy);
		}

		params.push(paramTy);
		paramNames.push(paramName);
	}

	if (params.length === 0) isVariadic = true; // f() means variadic in C
	expect(ctx, ")");

	const fn = makeFunc(returnTy);
	fn.params = params;
	fn.paramNames = paramNames;
	fn.isVariadic = isVariadic;
	return fn;
}

function arrayDimensions(ctx: ParseCtx, ty: CType): CType {
	// Skip static/restrict qualifiers
	while (eq(ctx, "static") || eq(ctx, "restrict")) advance(ctx);

	if (eq(ctx, "]")) {
		advance(ctx);
		ty = typeSuffix(ctx, ty);
		return makeArray(ty, -1); // incomplete array
	}

	// Parse constant expression for array size
	let size = 0;
	if (!eq(ctx, "]")) {
		const evalResult = evalConstExpr(ctx.tok, ctx.enumConstants);
		if (evalResult.ok) {
			size = evalResult.value as number;
			ctx.tok = evalResult.tok;
		}
	}
	expect(ctx, "]");
	ty = typeSuffix(ctx, ty);
	return makeArray(ty, size);
}

// ===== Declarator =====

interface DeclResult {
	type: CType;
	name: string;
}

function declarator(ctx: ParseCtx, ty: CType): DeclResult {
	ty = pointers(ctx, ty);

	// Grouped declarator: (declarator)
	if (eq(ctx, "(") && !isTypename(ctx) && ctx.tok.next !== null && ctx.tok.next.stringVal !== ")") {
		// Lookahead: is this a grouped declarator or a function parameter list?
		// If next token after ( is * or an identifier followed by ) or [ or (, it's grouped.
		const next = ctx.tok.next;
		if (next !== null && (next.stringVal === "*" || (next.kind === TokenKind.Ident && !isTypenameStr(ctx, next.stringVal)))) {
			const saved = ctx.tok;
			advance(ctx); // skip (
			// First pass: skip the declarator to find )
			skipDeclarator(ctx);
			expect(ctx, ")");
			// Apply suffix (array/function) to the OUTER type
			ty = typeSuffix(ctx, ty);
			// Save position after first pass (past all suffixes)
			const afterSuffix = ctx.tok;
			// Second pass: re-parse the inner declarator with the resolved type
			ctx.tok = saved.next;
			const inner = declarator(ctx, ty);
			// Restore position to after the suffix (skip tokens consumed in first pass)
			ctx.tok = afterSuffix;
			return inner;
		}
	}

	// Identifier
	let name = "";
	if (ctx.tok.kind === TokenKind.Ident && !ctx.typedefs.has(ctx.tok.stringVal)) {
		name = ctx.tok.stringVal;
		advance(ctx);
	}

	ty = typeSuffix(ctx, ty);
	return { type: ty, name };
}

const TYPE_KEYWORDS: string[] = [
	"void", "char", "short", "int", "long", "float", "double",
	"signed", "unsigned", "_Bool", "struct", "union", "enum",
];

function isTypenameStr(ctx: ParseCtx, s: string): boolean {
	for (const kw of TYPE_KEYWORDS) {
		if (s === kw) return true;
	}
	return ctx.typedefs.has(s);
}

// Skip a declarator without building a type (for the spiral rule first pass).
function skipDeclarator(ctx: ParseCtx): void {
	while (consume(ctx, "*")) {
		while (eq(ctx, "const") || eq(ctx, "volatile") || eq(ctx, "restrict") ||
			   eq(ctx, "__restrict") || eq(ctx, "__restrict__")) advance(ctx);
	}
	if (eq(ctx, "(")) {
		advance(ctx);
		skipDeclarator(ctx);
		expect(ctx, ")");
	} else if (ctx.tok.kind === TokenKind.Ident) {
		advance(ctx);
	}
	// Skip suffix
	if (eq(ctx, "(")) {
		advance(ctx);
		let depth = 1;
		while (!isEnd(ctx) && depth > 0) {
			if (eq(ctx, "(")) depth = depth + 1;
			if (eq(ctx, ")")) depth = depth - 1;
			if (depth > 0) advance(ctx);
		}
		if (eq(ctx, ")")) advance(ctx);
	} else if (eq(ctx, "[")) {
		advance(ctx);
		while (!isEnd(ctx) && !eq(ctx, "]")) advance(ctx);
		if (eq(ctx, "]")) advance(ctx);
	}
}

// typename = declspec abstract-declarator
function typename(ctx: ParseCtx): CType {
	const dummyAttr = newVarAttr();
	let ty = declspec(ctx, dummyAttr);
	ty = pointers(ctx, ty);
	ty = typeSuffix(ctx, ty);
	return ty;
}

// ===== Struct / Union =====

function structOrUnionDecl(ctx: ParseCtx, isUnion: boolean): CType {
	while (eq(ctx, "__attribute__")) skipAttribute(ctx);

	// Optional tag name
	let tagName = "";
	if (ctx.tok !== null && ctx.tok.kind === TokenKind.Ident &&
		ctx.tok.next !== null && ctx.tok.next.stringVal !== ";") {
		tagName = ctx.tok.stringVal;
		advance(ctx);
	}

	// No body: forward declaration or reference
	if (!eq(ctx, "{")) {
		if (tagName !== "" && ctx.tags.has(tagName)) {
			return ctx.tags.get(tagName) as CType;
		}
		const ty = isUnion ? makeUnion() : makeStruct();
		ty.tagName = tagName;
		if (tagName !== "") ctx.tags.set(tagName, ty);
		return ty;
	}

	// Parse body
	const existing = tagName !== "" && ctx.tags.has(tagName);
	const ty = existing ? ctx.tags.get(tagName) as CType : (isUnion ? makeUnion() : makeStruct());
	ty.tagName = tagName;
	if (tagName !== "") ctx.tags.set(tagName, ty);

	advance(ctx); // skip {
	ty.members = structMembers(ctx);
	expect(ctx, "}");

	while (eq(ctx, "__attribute__")) skipAttribute(ctx);

	if (isUnion) computeUnionLayout(ty);
	else computeStructLayout(ty);
	return ty;
}

function structDecl(ctx: ParseCtx): CType {
	return structOrUnionDecl(ctx, false);
}

function unionDecl(ctx: ParseCtx): CType {
	return structOrUnionDecl(ctx, true);
}

function structMembers(ctx: ParseCtx): CMember[] {
	const members: CMember[] = [];

	while (!eq(ctx, "}") && !isEnd(ctx)) {
		// Skip __attribute__
		while (eq(ctx, "__attribute__")) skipAttribute(ctx);

		const dummyAttr = newVarAttr();
		const baseTy = declspec(ctx, dummyAttr);

		// Handle multiple declarators: int a, b, c;
		let first = true;
		while (!eq(ctx, ";") && !isEnd(ctx)) {
			if (!first) expect(ctx, ",");
			first = false;

			const declResult = declarator(ctx, baseTy);
			let memTy = declResult.type;
			const memName = declResult.name;

			// Bitfield: int x : 3;
			let bitWidth = -1;
			if (consume(ctx, ":")) {
				if (ctx.tok.kind === TokenKind.Num) {
					bitWidth = ctx.tok.intVal as number;
					advance(ctx);
				}
			}

			const mem = makeMember(memName, memTy);
			mem.bitWidth = bitWidth;
			if (bitWidth >= 0) mem.bitOffset = 0;
			members.push(mem);
		}
		expect(ctx, ";");
	}

	return members;
}

// ===== Enum =====

function enumSpecifier(ctx: ParseCtx): CType {
	while (eq(ctx, "__attribute__")) skipAttribute(ctx);

	let tagName = "";
	if (ctx.tok !== null && ctx.tok.kind === TokenKind.Ident &&
		ctx.tok.next !== null && ctx.tok.next.stringVal !== ";") {
		tagName = ctx.tok.stringVal;
		advance(ctx);
	}

	if (!eq(ctx, "{")) {
		if (tagName !== "" && ctx.tags.has(tagName)) {
			return ctx.tags.get(tagName) as CType;
		}
		const ty = makeEnum(ctx.target);
		ty.tagName = tagName;
		if (tagName !== "") ctx.tags.set(tagName, ty);
		return ty;
	}

	const ty = makeEnum(ctx.target);
	ty.tagName = tagName;
	if (tagName !== "") ctx.tags.set(tagName, ty);

	advance(ctx); // skip {
	let enumVal: int64 = 0 as int64;

	while (!eq(ctx, "}") && !isEnd(ctx)) {
		const name = ctx.tok.stringVal;
		advance(ctx);

		if (consume(ctx, "=")) {
			const evalResult = evalConstExpr(ctx.tok, ctx.enumConstants);
			if (evalResult.ok) {
				enumVal = evalResult.value;
				ctx.tok = evalResult.tok;
			}
		}

		// Register enum constant as an Obj and in the constants map
		ctx.objs.push({
			kind: ObjKind.EnumConstant,
			name,
			type: ty,
			isStatic: false,
			isExtern: false,
			isDefinition: true,
			enumValue: enumVal,
			file: ctx.tok.file,
			line: ctx.tok.line,
		});
		ctx.enumConstants.set(name, enumVal);

		enumVal = (enumVal + (1 as int64)) as int64;
		if (!eq(ctx, "}")) expect(ctx, ",");
	}
	expect(ctx, "}");

	return ty;
}

// ===== Skip Function Body =====

function skipFunctionBody(ctx: ParseCtx): void {
	expect(ctx, "{");
	let depth = 1;
	while (!isEnd(ctx) && depth > 0) {
		if (eq(ctx, "{")) depth = depth + 1;
		if (eq(ctx, "}")) depth = depth - 1;
		if (depth > 0) advance(ctx);
	}
	if (eq(ctx, "}")) advance(ctx);
}

// ===== Top-Level Parse Loop =====

export function parseTranslationUnit(head: Token, target: TargetInfo): ParseResult {
	const ctx: ParseCtx = {
		tok: head,
		target,
		diags: [],
		objs: [],
		typedefs: new Map(),
		tags: new Map(),
		enumConstants: new Map<string, int64>(),
	};

	while (!isEnd(ctx)) {
		// Skip stray semicolons
		if (consume(ctx, ";")) continue;

		const attr = newVarAttr();
		const baseTy = declspec(ctx, attr);

		// typedef
		if (attr.isTypedef) {
			parseTypedef(ctx, baseTy);
			continue;
		}

		// Parse declarator
		const declResult = declarator(ctx, baseTy);
		const ty = declResult.type;
		const name = declResult.name;

		// Function declaration or definition
		if (ty.kind === CTypeKind.Func) {
			if (eq(ctx, "{")) {
				// Function definition — skip body
				skipFunctionBody(ctx);
			} else {
				expect(ctx, ";");
			}
			ctx.objs.push({
				kind: ObjKind.Function,
				name,
				type: ty,
				isStatic: attr.isStatic,
				isExtern: attr.isExtern,
				isDefinition: false,
				enumValue: 0 as int64,
				file: ctx.tok.file,
				line: ctx.tok.line,
			});
			continue;
		}

		// Variable declaration(s)
		ctx.objs.push({
			kind: ObjKind.Variable,
			name,
			type: ty,
			isStatic: attr.isStatic,
			isExtern: attr.isExtern,
			isDefinition: !attr.isExtern,
			enumValue: 0 as int64,
			file: ctx.tok.file,
			line: ctx.tok.line,
		});

		// Handle multiple declarators: int a, b;
		while (consume(ctx, ",")) {
			const declResult2 = declarator(ctx, baseTy);
			const ty2 = declResult2.type;
			const name2 = declResult2.name;
			ctx.objs.push({
				kind: ObjKind.Variable,
				name: name2,
				type: ty2,
				isStatic: attr.isStatic,
				isExtern: attr.isExtern,
				isDefinition: !attr.isExtern,
				enumValue: 0 as int64,
				file: ctx.tok.file,
				line: ctx.tok.line,
			});
		}

		// Skip initializer: = expr
		if (consume(ctx, "=")) {
			while (!isEnd(ctx) && !eq(ctx, ";") && !eq(ctx, ",")) advance(ctx);
		}

		expect(ctx, ";");
	}

	return { objs: ctx.objs, diagnostics: ctx.diags };
}

// ===== Typedef =====

function parseTypedef(ctx: ParseCtx, baseTy: CType): void {
	let first = true;
	while (!eq(ctx, ";") && !isEnd(ctx)) {
		if (!first) expect(ctx, ",");
		first = false;

		const declResult = declarator(ctx, baseTy);
		const ty = declResult.type;
		const name = declResult.name;

		if (name !== "") {
			ctx.typedefs.set(name, ty);
			ctx.objs.push({
				kind: ObjKind.TypedefName,
				name,
				type: ty,
				isStatic: false,
				isExtern: false,
				isDefinition: true,
				enumValue: 0 as int64,
				file: ctx.tok.file,
				line: ctx.tok.line,
			});
		}
	}
	expect(ctx, ";");
}

// ===== Tests =====

import { tokenizeFile } from "./tokenize";
import { preprocess } from "./preprocess";
import { targetLinuxX86_64 } from "./target";

function parseTest(source: string): ParseResult {
	const target = targetLinuxX86_64();
	const tokens = tokenizeFile(source, "test.h");
	const pp = preprocess(tokens.head, target, []);
	return parseTranslationUnit(pp.head, target);
}

function findObj(result: ParseResult, name: string): Obj {
	for (const obj of result.objs) {
		if (obj.name === name) return obj;
	}
	return null as unknown as Obj;
}

function runParseTests(): void {
	let passed = 0;
	let failed = 0;

	// Test 1: extern function
	{
		const r = parseTest("extern int add(int a, int b);");
		const obj = findObj(r, "add");
		if (obj !== null && obj.kind === ObjKind.Function && obj.type.kind === CTypeKind.Func
			&& obj.type.returnType.kind === CTypeKind.Int && obj.type.params.length === 2) {
			passed = passed + 1;
			console.log("  PASS: parse extern function");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse extern function");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 2: extern variable
	{
		const r = parseTest("extern int counter;");
		const obj = findObj(r, "counter");
		if (obj !== null && obj.kind === ObjKind.Variable && obj.type.kind === CTypeKind.Int && obj.isExtern === true) {
			passed = passed + 1;
			console.log("  PASS: parse extern variable");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse extern variable");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 3: typedef simple
	{
		const r = parseTest("typedef int MyInt;");
		const obj = findObj(r, "MyInt");
		if (obj !== null && obj.kind === ObjKind.TypedefName && obj.type.kind === CTypeKind.Int) {
			passed = passed + 1;
			console.log("  PASS: parse typedef simple");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse typedef simple");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 4: typedef pointer
	{
		const r = parseTest("typedef const char *CString;");
		const obj = findObj(r, "CString");
		if (obj !== null && obj.type.kind === CTypeKind.Ptr) {
			passed = passed + 1;
			console.log("  PASS: parse typedef pointer");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse typedef pointer");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 5: typedef function pointer
	{
		const r = parseTest("typedef int (*CompareFn)(const void *, const void *);");
		const obj = findObj(r, "CompareFn");
		if (obj !== null && obj.type.kind === CTypeKind.Ptr && obj.type.base.kind === CTypeKind.Func) {
			passed = passed + 1;
			console.log("  PASS: parse typedef function pointer");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse typedef function pointer");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 6: typedef struct
	{
		const r = parseTest("typedef struct { int x; int y; } Point;");
		const obj = findObj(r, "Point");
		if (obj !== null && obj.type.kind === CTypeKind.Struct && obj.type.members.length === 2) {
			passed = passed + 1;
			console.log("  PASS: parse typedef struct");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse typedef struct");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 7: named struct with self-ref
	{
		const r = parseTest("typedef struct Node { int value; struct Node *next; } Node;");
		const obj = findObj(r, "Node");
		if (obj !== null && obj.type.kind === CTypeKind.Struct && obj.type.members.length === 2
			&& obj.type.members[1].type.kind === CTypeKind.Ptr) {
			passed = passed + 1;
			console.log("  PASS: parse named struct with self-ref");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse named struct with self-ref");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 8: union
	{
		const r = parseTest("typedef union { int i; float f; } IntOrFloat;");
		const obj = findObj(r, "IntOrFloat");
		if (obj !== null && obj.type.kind === CTypeKind.Union && obj.type.members.length === 2) {
			passed = passed + 1;
			console.log("  PASS: parse union");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse union");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 9: enum with values
	{
		const r = parseTest("typedef enum { FLAG_NONE = 0, FLAG_READ = 1, FLAG_WRITE = 2 } Flags;");
		const obj = findObj(r, "Flags");
		const read = findObj(r, "FLAG_READ");
		if (obj !== null && obj.type.kind === CTypeKind.Enum
			&& read !== null && read.kind === ObjKind.EnumConstant && read.enumValue === 1 as int64) {
			passed = passed + 1;
			console.log("  PASS: parse enum with values");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse enum with values");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 10: variadic function
	{
		const r = parseTest("extern void log_msg(const char *fmt, ...);");
		const obj = findObj(r, "log_msg");
		if (obj !== null && obj.type.isVariadic === true) {
			passed = passed + 1;
			console.log("  PASS: parse variadic function");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse variadic function");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 11: static const
	{
		const r = parseTest("static const int MAX = 256;");
		const obj = findObj(r, "MAX");
		if (obj !== null && obj.isStatic === true) {
			passed = passed + 1;
			console.log("  PASS: parse static const");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse static const");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 12: unsigned long long
	{
		const r = parseTest("extern unsigned long long big;");
		const obj = findObj(r, "big");
		if (obj !== null && obj.type.kind === CTypeKind.LongLong && obj.type.isSigned === false) {
			passed = passed + 1;
			console.log("  PASS: parse unsigned long long");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse unsigned long long");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 13: function pointer parameter
	// KNOWN ISSUE: C backend byteSlice bug drops first byte of "void" string.
	// Affects any test where "void" appears in source. Parser logic is correct
	// (verified in Bun/JS backend). The function pointer parsing itself works
	// (see test 5: typedef function pointer).
	{
		const r = parseTest("extern void qsort(void *base, int n, int size, int (*cmp)(const void *, const void *));");
		const obj = findObj(r, "qsort");
		if (obj !== null && obj.type.params.length === 4
			&& obj.type.params[3].kind === CTypeKind.Ptr
			&& obj.type.params[3].base.kind === CTypeKind.Func) {
			passed = passed + 1;
			console.log("  PASS: parse function pointer parameter");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse function pointer parameter");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 14: typedef used in later decl
	{
		const r = parseTest("typedef int MyInt;\nextern MyInt x;");
		const obj = findObj(r, "x");
		if (obj !== null && obj.type.kind === CTypeKind.Int) {
			passed = passed + 1;
			console.log("  PASS: parse typedef used in later decl");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse typedef used in later decl");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 15: void params
	// KNOWN ISSUE: Same C backend "void" byteSlice bug. Parser logic correct in JS.
	{
		const r = parseTest("extern int getpid(void);");
		const obj = findObj(r, "getpid");
		if (obj !== null && obj.type.params.length === 0 && obj.type.isVariadic === false) {
			passed = passed + 1;
			console.log("  PASS: parse function with void params");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse function with void params");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	// Test 16: skip function body
	{
		const r = parseTest("static inline int max(int a, int b) { return a > b ? a : b; }\nextern int x;");
		const obj = findObj(r, "x");
		if (obj !== null && obj.kind === ObjKind.Variable) {
			passed = passed + 1;
			console.log("  PASS: parse skip function body");
		} else {
			failed = failed + 1;
			console.log("  FAIL: parse skip function body");
			if (r.diagnostics.length > 0) {
				for (const d of r.diagnostics) console.log("    diag: " + d.message);
			}
		}
	}

	console.log("Parser tests: " + passed.toString() + " passed, " + failed.toString() + " failed");
}

runParseTests();
