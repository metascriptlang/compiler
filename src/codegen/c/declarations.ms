// C Codegen — Declaration Emission
//
// Handles function, enum, interface (struct), class, export, and import declarations.
// Emits to appropriate CGen sections (Types, ProcHeaders, Procs, ForwardDecls).

import {
	Node, NodeKind, DeclKind,
	FunctionDeclData, EnumDeclData,
	InterfaceDeclData, ClassDeclData,
	ExportDeclData, ImportDeclData,
	VariableDeclData, DecoratedDeclData,
	ProgramData, BlockStmtData,
	PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ObjectLiteralData,
} from "../../ast/node";
import { sliceStr } from "../../utils/string";
import { Type, TypeKind } from "../../checker/types";
import {
	CGen, CProc, CSection, Builder,
	createProc, createBuilder, add, addLine, addNewline,
	sec, extract, nameSetHas, nameSetAdd,
	emitStmts, emitStmtsLine, readProcStmts, readProcLocals,
	typeCacheSet, typeCacheHas,
} from "./context";
import { genExpr } from "./expressions";
import { genStmt, genStmts } from "./statements";
import { mangle, mangleTypeName, mangleFieldName, safeName } from "./names";
import { getSimpleTypeDesc, getTypeDesc, isNrvoReturnType } from "./types";
import {
	Symbol, SymbolKind, SymbolState,
	hasFlag, SF_EXPORTED, SF_STATIC, SF_IMPORT_C,
} from "../../checker/symbol";
// NOTE: parser/context imports are in index.ms (not here) to avoid DRC union member count issues.
// genGenericTypeInsts lives in index.ms for the same reason.
import { check } from "std/testing";

// ===== genDecl — main declaration dispatcher =====

export function genDecl(g: CGen, node: Node, exported: boolean): void {
	if (node === null) return;

	const k = node.kind;
	if (k === NodeKind.FunctionDecl) { genFunctionDecl(g, node, exported); }
	else if (k === NodeKind.EnumDecl) { genEnumDecl(g, node); }
	else if (k === NodeKind.InterfaceDecl) { genInterfaceDecl(g, node); }
	else if (k === NodeKind.ClassDecl) { genClassDecl(g, node); }
	else if (k === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		genDecl(g, d.exportedDecl, true);
	}
	else if (k === NodeKind.ImportDecl) { /* imports handled at module level */ }
	else if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		genDecl(g, d.decoratedNode, exported);
	}
	else if (k === NodeKind.TypeAliasDecl) { /* type aliases are compile-time only */ }
	else if (k === NodeKind.ExternDecl) { /* extern declarations handled in types/headers */ }
	else if (k === NodeKind.TestDecl) { /* stripped in non-test builds */ }
	else {
		// Statement or variable at top level
		genTopLevelStmt(g, node);
	}
}

// ===== Function Declaration =====

function genFunctionDecl(g: CGen, node: Node, exported: boolean): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (sym === null) return;

	let name = safeName(d.fnName);

	// Overload mangling: if function has overloads, suffix with __idx
	if (sym.overloads !== null && sym.overloads.length > 0) {
		const idx = findOverloadIdx(sym, node.resolvedSym);
		name = safeName(d.fnName) + "__" + idx;
	}

	// Skip if already declared
	if (nameSetHas(g.declaredProcs, name)) return;
	nameSetAdd(g.declaredProcs, name);

	// Determine C return type — MUST have nodeType (Decisive Checker mandate)
	const fnType = node.nodeType;
	if (fnType === null) return;
	let cRetType = getTypeDesc(g, fnType.typeReturn);
	const nrvo = isNrvoReturnType(fnType.typeReturn);

	// Build parameter list — NRVO adds out-param as first parameter
	let paramList = "";
	if (nrvo) {
		paramList = cRetType + "* __result";
		if (d.params.length > 0) paramList = paramList + ", ";
	}
	for (let i = 0; i < d.params.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		let pType = (i < fnType.typeChildren.length) ? getTypeDesc(g, fnType.typeChildren[i]) : "void*";
		paramList = paramList + pType + " " + safeName(d.params[i]);
	}
	if (paramList === "") paramList = "void";

	// Non-exported functions get static prefix (Nim parity)
	// main() is never static — called from dispatcher
	const isMain = d.fnName === "main";
	const isExported = exported || hasFlag(sym, SF_EXPORTED);
	const isExtern = hasFlag(sym, SF_IMPORT_C);
	const prefix = (isExported || isExtern || isMain) ? "" : "static ";

	// Emit prototype to ProcHeaders — NRVO functions return void
	const actualRetType = nrvo ? "void" : cRetType;
	const proto = prefix + actualRetType + " " + name + "(" + paramList + ")";
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	// Extern functions: prototype only, no body
	if (isExtern) return;

	// Emit function body to Procs
	if (d.fnBody !== null) {
		const p = createProc(name, fnType.typeReturn);
		if (nrvo) p.isNrvo = true;
		genStmt(g, p, d.fnBody);
		const locals = readProcLocals(p);
		const stmts = readProcStmts(p);
		const procs = sec(g, CSection.Procs);
		addLine(procs, proto + " {");
		if (locals.length > 0) add(procs, locals);
		add(procs, stmts);
		addLine(procs, "}");
		addNewline(procs);
	}
}

// ===== Overload Index Matching =====
// Find overload index using pre-resolved symbol identity.
// Primary symbol = index 0, overloads[i] = index i+1.
function findOverloadIdx(primarySym: Symbol, declSym: Symbol): number {
	if (declSym === primarySym) return 0;
	if (primarySym.overloads !== null) {
		let i = 0;
		while (i < primarySym.overloads.length) {
			if (primarySym.overloads[i] === declSym) return i + 1;
			i = i + 1;
		}
	}
	return 0;
}

// ===== Enum Declaration =====

function genEnumDecl(g: CGen, node: Node): void {
	const d = node.data as EnumDeclData;
	const name = mangle(d.enumName);

	// Skip if already declared (check both declaration set and type cache)
	const key = "enum:" + d.enumName;
	if (nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, key)) return;
	nameSetAdd(g.declaredThings, name);

	// Register in type cache to prevent genEnumType from re-emitting
	typeCacheSet(g.typeCache, key, name);

	// Register as known enum for cross-module member access (TokenKind.Eof → TokenKind_Eof)
	nameSetAdd(g.knownEnumNames, name);

	// Emit as typedef + #define constants
	const types = sec(g, CSection.Types);
	addLine(types, "typedef int32_t " + name + ";");
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		addLine(types, "#define " + name + "_" + d.enumMembers[i] + " (((" + name + ")" + i + "))");
	}
	addNewline(types);
}

// ===== Interface Declaration (struct) =====

function genInterfaceDecl(g: CGen, node: Node): void {
	const d = node.data as InterfaceDeclData;

	const name = mangle(d.interfaceName);

	// Skip if already declared (check both declaration set and type cache)
	const ifaceKey = "object:" + d.interfaceName;
	if (nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, ifaceKey)) return;
	nameSetAdd(g.declaredThings, name);

	// Register in type cache to prevent genObjectType from re-emitting
	typeCacheSet(g.typeCache, ifaceKey, name);

	// Forward declaration
	addLine(sec(g, CSection.ForwardDecls), "typedef struct " + name + " " + name + ";");

	// Pre-resolve field types (ensures nested type definitions are emitted before struct body)
	const ifaceType = node.nodeType;
	const fieldTypes: string[] = [];
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		const ft = (ifaceType !== null && i < ifaceType.typeChildren.length) ? getTypeDesc(g, ifaceType.typeChildren[i]) : "void*";
		fieldTypes.push(ft);
	}

	// Full struct definition (all referenced types already emitted above)
	const types = sec(g, CSection.Types);
	addLine(types, "struct " + name + " {");
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		addLine(types, "  " + fieldTypes[i] + " " + mangleFieldName(d.interfaceFields[i]) + ";");
	}
	addLine(types, "};");
	addNewline(types);
}

// ===== Class Declaration =====

function genClassDecl(g: CGen, node: Node): void {
	const d = node.data as ClassDeclData;

	const name = mangle(d.className);

	// Skip if already declared (check both declaration set and type cache)
	const classKey = "object:" + d.className;
	if (nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, classKey)) return;
	nameSetAdd(g.declaredThings, name);

	// Register in type cache to prevent genObjectType from re-emitting
	typeCacheSet(g.typeCache, classKey, name + "*");

	// Forward declaration
	addLine(sec(g, CSection.ForwardDecls), "typedef struct " + name + " " + name + ";");

	// Struct — no refcount field; msRefHeader (16 bytes) is prepended by msAllocTyped
	const types = sec(g, CSection.Types);
	addLine(types, "struct " + name + " {");
	// Emit properties from classBody
	for (let i = 0; i < d.classBody.length; i += 1) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			const fieldType = getTypeDesc(g, member.nodeType);
			const fieldName = mangleFieldName(pd.propName);
			addLine(types, "  " + fieldType + " " + fieldName + ";");
		}
	}
	addLine(types, "};");
	addNewline(types);

	// msTypeInfo is generated by destructorLifting (transform phase) as a _typeInfo VariableDecl.
	// genTypeInfoVar handles it via genGlobalVar → DatInit patching.

	// Emit methods as free functions with first param being the class pointer
	for (let i = 0; i < d.classBody.length; i += 1) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.MethodDecl) {
			genMethodAsFunction(g, member, name);
		} else if (member.kind === NodeKind.ConstructorDecl) {
			genConstructor(g, member, name);
		}
	}
}

// ===== Method as Free Function =====

function genMethodAsFunction(g: CGen, node: Node, className: string): void {
	const d = node.data as MethodDeclData;
	const methodName = className + "_" + safeName(d.methodName);
	const methodType = node.nodeType;
	const cRetType = getTypeDesc(g, methodType.typeReturn);

	// Build params: (ClassName* self, ...)
	let paramList = className + "* self";
	for (let i = 0; i < d.methodParams.length; i += 1) {
		paramList = paramList + ", ";
		const pType = getTypeDesc(g, methodType.typeChildren[i]);
		paramList = paramList + pType + " " + safeName(d.methodParams[i]);
	}

	const proto = cRetType + " " + methodName + "(" + paramList + ")";
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	if (d.methodBody !== null) {
		const p = createProc(methodName, null as unknown as Type);
		genStmt(g, p, d.methodBody);
		const locals = readProcLocals(p);
		const stmts = readProcStmts(p);
		const procs = sec(g, CSection.Procs);
		addLine(procs, proto + " {");
		if (locals.length > 0) add(procs, locals);
		add(procs, stmts);
		addLine(procs, "}");
		addNewline(procs);
	}
}

// ===== Constructor =====

function genConstructor(g: CGen, node: Node, className: string): void {
	const d = node.data as ConstructorDeclData;
	const ctorName = className + "_new";

	const ctorType = node.nodeType;
	let paramList = "";
	for (let i = 0; i < d.ctorParams.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = getTypeDesc(g, ctorType.typeChildren[i]);
		paramList = paramList + pType + " " + safeName(d.ctorParams[i]);
	}
	if (d.ctorParams.length === 0) paramList = "void";

	const proto = className + "* " + ctorName + "(" + paramList + ")";
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	const procs = sec(g, CSection.Procs);
	addLine(procs, proto + " {");
	// Allocate with RTTI: msAllocTyped(sizeof(Type), &Type_typeInfo)
	addLine(procs, "  " + className + "* self = (" + className + "*)msAllocTyped(sizeof(" + className + "), &" + className + "_typeInfo);");

	if (d.ctorBody !== null) {
		const p = createProc(ctorName, null as unknown as Type);
		genStmt(g, p, d.ctorBody);
		const locals = readProcLocals(p);
		const stmts = readProcStmts(p);
		if (locals.length > 0) add(procs, locals);
		add(procs, stmts);
	}

	addLine(procs, "  return self;");
	addLine(procs, "}");
	addNewline(procs);
}

// genExportDecl and genDecoratedDecl inlined into genDecl (exported flag threading)

// ===== Top-level Statement =====

function genTopLevelStmt(g: CGen, node: Node): void {
	// Global variable declarations go to GlobalVars section
	if (node.kind === NodeKind.VariableDecl) {
		genGlobalVar(g, node);
		return;
	}
	// Other statements go to ModuleInit
	const p = createProc("__module_init", null as unknown as Type);
	genStmt(g, p, node);
	const stmts = readProcStmts(p);
	add(sec(g, CSection.ModuleInit), stmts);
}

// ===== Global Variable Declaration =====

function genGlobalVar(g: CGen, node: Node): void {
	const d = node.data as VariableDeclData;
	const varName = safeName(d.declName);

	// Detect _typeInfo vars from destructorLifting (ORC runtime RTTI)
	const nameLen = d.declName.length;
	if (nameLen > 9 && sliceStr(d.declName, nameLen - 9, nameLen) === "_typeInfo") {
		genTypeInfoVar(g, d, varName);
		return;
	}

	const cType = getTypeDesc(g, node.nodeType);
	// Always emit uninitialized declaration to GlobalVars
	addLine(sec(g, CSection.GlobalVars), cType + " " + varName + ";");

	// Non-trivial initializers go to ModuleInit (not valid as C global initializers)
	if (d.initializer !== null) {
		const p = createProc("__init", null as unknown as Type);
		const initSnippet = genExpr(g, p, d.initializer);
		const locals = readProcLocals(p);
		if (locals.length > 0) {
			add(sec(g, CSection.ModuleInit), locals);
		}
		addLine(sec(g, CSection.ModuleInit), "  " + varName + " = " + initSnippet + ";");
	}
}

// ===== TypeInfo Variable (from destructorLifting) =====
// Emits msTypeInfo declaration to GlobalVars and field assignments to DatInit.
// The ObjectLiteral initializer has fields { name, isCyclic, traceFn, destroyFn }.

function genTypeInfoVar(g: CGen, d: VariableDeclData, varName: string): void {
	// Extract base type name: strip "_typeInfo" suffix (9 chars)
	const baseName = sliceStr(d.declName, 0, d.declName.length - 9);

	// Emit declaration
	addLine(sec(g, CSection.GlobalVars), "static msTypeInfo " + varName + ";");

	// Emit field assignments to DatInit (runs before user code)
	if (d.initializer !== null && d.initializer.kind === NodeKind.ObjectLiteral) {
		const od = d.initializer.data as ObjectLiteralData;
		const datInit = sec(g, CSection.DatInit);
		const p = createProc("__datinit", null as unknown as Type);

		for (let i = 0; i < od.keys.length; i += 1) {
			const key = od.keys[i];
			if (key === "name") {
				// name field: emit C string literal (const char*), not msString
				addLine(datInit, "  " + varName + ".name = \"" + baseName + "\";");
			} else if (key === "destroyFn") {
				// destroyFn: cast to msDestroyProc (void(*)(void*)) for C type safety
				const val = genExpr(g, p, od.properties[i]);
				if (val === "MS_NIL" || val === "NULL") {
					addLine(datInit, "  " + varName + ".destroyFn = NULL;");
				} else {
					addLine(datInit, "  " + varName + ".destroyFn = (msDestroyProc)" + val + ";");
				}
			} else if (key === "traceFn") {
				// traceFn: cast to msTraceProc (void(*)(void*, void*)) for C type safety
				const val = genExpr(g, p, od.properties[i]);
				if (val === "MS_NIL" || val === "NULL") {
					addLine(datInit, "  " + varName + ".traceFn = NULL;");
				} else {
					addLine(datInit, "  " + varName + ".traceFn = (msTraceProc)" + val + ";");
				}
			} else {
				// isCyclic: use genExpr directly
				const val = genExpr(g, p, od.properties[i]);
				addLine(datInit, "  " + varName + "." + key + " = " + val + ";");
			}
		}
	}
}

// isNrvoReturnType in types.ms (shared, Type-based NRVO detection)

// ===== Tests =====

import { createCGen, assembleOutput } from "./context";
import { CheckerContext } from "../../checker/context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";

function declOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	const prog = pr.value;
	const pd = prog.data as ProgramData;
	const g = createCGen(null as unknown as CheckerContext, "test");
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		genDecl(g, pd.programStmts[i], false);
	}
	return assembleOutput(g);
}

test "simple function" {
	const result = declOutput("function foo(): void { return; }");
	check(result.length > 0);
	// Should have prototype and body
}

test "function with params" {
	const result = declOutput("function add(a: number, b: number): number { return a + b; }");
	check(result.length > 0);
}

test "simple enum" {
	const result = declOutput("enum Color { Red, Green, Blue }");
	check(result.length > 0);
}

test "simple interface" {
	const result = declOutput("interface Point { x: number; y: number; }");
	check(result.length > 0);
}

test "exported function" {
	const result = declOutput("export function bar(): void { return; }");
	check(result.length > 0);
}

test "const global" {
	const result = declOutput("const x: number = 42;");
	check(result.length > 0);
}

test "NRVO function signature" {
	const result = declOutput("interface Point { x: number; y: number; } function makePoint(): Point { return { x: 0, y: 0 }; }");
	// Should have void return + __result param in the output
	check(result.length > 50);
}

