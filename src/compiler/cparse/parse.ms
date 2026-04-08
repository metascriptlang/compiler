// cparse — Declaration parser
// Port of: ~/projects/chibicc parse.c (declaration-level subset only).
//
// Parses preprocessed tokens into top-level declarations (Obj[]).
// Skips function bodies (brace-matched), full expression parsing, and statements.

import { Token, TokenKind, LitKind } from "./token";
import { Obj, ObjKind } from "./obj";
import { Diagnostic, DiagSeverity, makeDiag } from "./error";
import { TargetInfo } from "./target";
import {
	CType, CTypeKind, CMember, makeVoid, makeBool, makeChar, makeUChar, makeSChar,
	makeShort, makeUShort, makeInt, makeUInt, makeLong, makeULong, makeLongLong,
	makeULongLong, makeFloat, makeDouble, makeLongDouble, makePointer, makeArray,
	makeFunc, makeEnum, makeStruct, makeUnion, makeMember, copyType,
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
	if (eq(ctx, "void") && ctx.tok.next.stringVal === ")") {
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

		const dummyAttr: VarAttr = { isTypedef: false, isStatic: false, isExtern: false, isInline: false };
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
	if (ctx.tok.kind === TokenKind.Num) {
		size = ctx.tok.intVal as number;
		advance(ctx);
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
	if (eq(ctx, "(") && !isTypename(ctx) && ctx.tok.next.stringVal !== ")") {
		// Lookahead: is this a grouped declarator or a function parameter list?
		// If next token after ( is * or an identifier followed by ) or [ or (, it's grouped.
		const next = ctx.tok.next;
		if (next.stringVal === "*" || (next.kind === TokenKind.Ident && !isTypenameStr(ctx, next.stringVal))) {
			const saved = ctx.tok;
			advance(ctx); // skip (
			// First pass: skip the declarator to find )
			skipDeclarator(ctx);
			expect(ctx, ")");
			// Apply suffix (array/function) to the OUTER type
			ty = typeSuffix(ctx, ty);
			// Second pass: re-parse the declarator with the correct type
			ctx.tok = saved.next;
			return declarator(ctx, ty);
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

function isTypenameStr(ctx: ParseCtx, s: string): boolean {
	return s === "void" || s === "char" || s === "short" || s === "int" || s === "long" ||
		s === "float" || s === "double" || s === "signed" || s === "unsigned" ||
		s === "_Bool" || s === "struct" || s === "union" || s === "enum" ||
		ctx.typedefs.has(s);
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
	const dummyAttr: VarAttr = { isTypedef: false, isStatic: false, isExtern: false, isInline: false };
	let ty = declspec(ctx, dummyAttr);
	ty = pointers(ctx, ty);
	ty = typeSuffix(ctx, ty);
	return ty;
}

// ===== Struct / Union =====

function structDecl(ctx: ParseCtx): CType {
	// Skip __attribute__
	while (eq(ctx, "__attribute__")) skipAttribute(ctx);

	// Optional tag name
	let tagName = "";
	if (ctx.tok.kind === TokenKind.Ident && ctx.tok.next.stringVal !== ";") {
		tagName = ctx.tok.stringVal;
		advance(ctx);
	}

	// No body: forward declaration or reference
	if (!eq(ctx, "{")) {
		if (tagName !== "" && ctx.tags.has(tagName)) {
			return ctx.tags.get(tagName) as CType;
		}
		const ty = makeStruct();
		ty.tagName = tagName;
		if (tagName !== "") ctx.tags.set(tagName, ty);
		return ty;
	}

	// Parse body
	const ty = (tagName !== "" && ctx.tags.has(tagName)) ? ctx.tags.get(tagName) as CType : makeStruct();
	ty.tagName = tagName;
	if (tagName !== "") ctx.tags.set(tagName, ty);

	advance(ctx); // skip {
	ty.members = structMembers(ctx);
	expect(ctx, "}");

	// Skip trailing __attribute__
	while (eq(ctx, "__attribute__")) skipAttribute(ctx);

	computeStructLayout(ty);
	return ty;
}

function unionDecl(ctx: ParseCtx): CType {
	while (eq(ctx, "__attribute__")) skipAttribute(ctx);

	let tagName = "";
	if (ctx.tok.kind === TokenKind.Ident && ctx.tok.next.stringVal !== ";") {
		tagName = ctx.tok.stringVal;
		advance(ctx);
	}

	if (!eq(ctx, "{")) {
		if (tagName !== "" && ctx.tags.has(tagName)) {
			return ctx.tags.get(tagName) as CType;
		}
		const ty = makeUnion();
		ty.tagName = tagName;
		if (tagName !== "") ctx.tags.set(tagName, ty);
		return ty;
	}

	const ty = (tagName !== "" && ctx.tags.has(tagName)) ? ctx.tags.get(tagName) as CType : makeUnion();
	ty.tagName = tagName;
	if (tagName !== "") ctx.tags.set(tagName, ty);

	advance(ctx); // skip {
	ty.members = structMembers(ctx);
	expect(ctx, "}");

	while (eq(ctx, "__attribute__")) skipAttribute(ctx);

	computeUnionLayout(ty);
	return ty;
}

function structMembers(ctx: ParseCtx): CMember[] {
	const members: CMember[] = [];

	while (!eq(ctx, "}") && !isEnd(ctx)) {
		// Skip __attribute__
		while (eq(ctx, "__attribute__")) skipAttribute(ctx);

		const dummyAttr: VarAttr = { isTypedef: false, isStatic: false, isExtern: false, isInline: false };
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
	if (ctx.tok.kind === TokenKind.Ident && ctx.tok.next.stringVal !== ";") {
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
			if (ctx.tok.kind === TokenKind.Num) {
				enumVal = ctx.tok.intVal;
				advance(ctx);
			}
		}

		// Register enum constant as an Obj
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
	};

	while (!isEnd(ctx)) {
		// Skip stray semicolons
		if (consume(ctx, ";")) continue;

		const attr: VarAttr = { isTypedef: false, isStatic: false, isExtern: false, isInline: false };
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

import { tokenizeFile, convertPPTokens } from "./tokenize";
import { preprocess } from "./preprocess";
import { targetLinuxX86_64 } from "./target";

function parse(source: string): ParseResult {
	const tokens = tokenizeFile(source, "test.h");
	const pp = preprocess(tokens.head, {} as unknown as TargetInfo, []);
	return parseTranslationUnit(pp.head, targetLinuxX86_64());
}

function findObj(result: ParseResult, name: string): Obj {
	for (const obj of result.objs) {
		if (obj.name === name) return obj;
	}
	return null as unknown as Obj;
}

test "parse extern function" {
	const r = parse("extern int add(int a, int b);");
	const obj = findObj(r, "add");
	assert obj !== null;
	assert obj.kind === ObjKind.Function;
	assert obj.type.kind === CTypeKind.Func;
	assert obj.type.returnType.kind === CTypeKind.Int;
	assert obj.type.params.length === 2;
}

test "parse extern variable" {
	const r = parse("extern int counter;");
	const obj = findObj(r, "counter");
	assert obj !== null;
	assert obj.kind === ObjKind.Variable;
	assert obj.type.kind === CTypeKind.Int;
	assert obj.isExtern === true;
}

test "parse typedef simple" {
	const r = parse("typedef int MyInt;");
	const obj = findObj(r, "MyInt");
	assert obj !== null;
	assert obj.kind === ObjKind.TypedefName;
	assert obj.type.kind === CTypeKind.Int;
}

test "parse typedef pointer" {
	const r = parse("typedef const char *CString;");
	const obj = findObj(r, "CString");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.Ptr;
}

test "parse typedef function pointer" {
	const r = parse("typedef int (*CompareFn)(const void *, const void *);");
	const obj = findObj(r, "CompareFn");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.Ptr;
	assert obj.type.base.kind === CTypeKind.Func;
}

test "parse typedef struct" {
	const r = parse("typedef struct { int x; int y; } Point;");
	const obj = findObj(r, "Point");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.Struct;
	assert obj.type.members.length === 2;
}

test "parse named struct with self-ref" {
	const r = parse("typedef struct Node { int value; struct Node *next; } Node;");
	const obj = findObj(r, "Node");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.Struct;
	assert obj.type.members.length === 2;
	assert obj.type.members[1].type.kind === CTypeKind.Ptr;
}

test "parse union" {
	const r = parse("typedef union { int i; float f; } IntOrFloat;");
	const obj = findObj(r, "IntOrFloat");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.Union;
	assert obj.type.members.length === 2;
}

test "parse enum with values" {
	const r = parse("typedef enum { FLAG_NONE = 0, FLAG_READ = 1, FLAG_WRITE = 2 } Flags;");
	const obj = findObj(r, "Flags");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.Enum;
	const read = findObj(r, "FLAG_READ");
	assert read !== null;
	assert read.kind === ObjKind.EnumConstant;
	assert read.enumValue === 1 as int64;
}

test "parse variadic function" {
	const r = parse("extern void log_msg(const char *fmt, ...);");
	const obj = findObj(r, "log_msg");
	assert obj !== null;
	assert obj.type.isVariadic === true;
}

test "parse static const" {
	const r = parse("static const int MAX = 256;");
	const obj = findObj(r, "MAX");
	assert obj !== null;
	assert obj.isStatic === true;
}

test "parse unsigned long long" {
	const r = parse("extern unsigned long long big;");
	const obj = findObj(r, "big");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.LongLong;
	assert obj.type.isSigned === false;
}

test "parse function pointer parameter" {
	const r = parse("extern void qsort(void *base, int n, int size, int (*cmp)(const void *, const void *));");
	const obj = findObj(r, "qsort");
	assert obj !== null;
	assert obj.type.params.length === 4;
	// Last param is a function pointer
	assert obj.type.params[3].kind === CTypeKind.Ptr;
	assert obj.type.params[3].base.kind === CTypeKind.Func;
}

test "parse typedef used in later decl" {
	const r = parse("typedef int MyInt;\nextern MyInt x;");
	const obj = findObj(r, "x");
	assert obj !== null;
	assert obj.type.kind === CTypeKind.Int;
}

test "parse function with void params" {
	const r = parse("extern int getpid(void);");
	const obj = findObj(r, "getpid");
	assert obj !== null;
	assert obj.type.params.length === 0;
	// (void) means NOT variadic (unlike empty ())
	assert obj.type.isVariadic === false;
}

test "parse skip function body" {
	const r = parse("static inline int max(int a, int b) { return a > b ? a : b; }\nextern int x;");
	const obj = findObj(r, "x");
	assert obj !== null;
	assert obj.kind === ObjKind.Variable;
}
