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
} from "../../ast/node";
import { Type, TypeKind } from "../../checker/types";
import {
	CGen, CProc, CSection, Builder,
	createProc, createBuilder, add, addLine, addNewline,
	sec, extract, nameSetHas, nameSetAdd,
	emitStmts, emitStmtsLine, readProcStmts, readProcLocals,
} from "./context";
import { genExpr } from "./expressions";
import { genStmt, genStmts } from "./statements";
import { mangle, mangleTypeName, mangleFieldName, safeName } from "./names";
// NOTE: parser/context imports are in index.ms (not here) to avoid DRC union member count issues.
// genGenericTypeInsts lives in index.ms for the same reason.
import { test, check, testGroup } from "std/testing";

// ===== genDecl — main declaration dispatcher =====

export function genDecl(g: CGen, node: Node): void {
	if (node === null) return;

	const k = node.kind;
	if (k === NodeKind.FunctionDecl) { genFunctionDecl(g, node); }
	else if (k === NodeKind.EnumDecl) { genEnumDecl(g, node); }
	else if (k === NodeKind.InterfaceDecl) { genInterfaceDecl(g, node); }
	else if (k === NodeKind.ClassDecl) { genClassDecl(g, node); }
	else if (k === NodeKind.ExportDecl) { genExportDecl(g, node); }
	else if (k === NodeKind.ImportDecl) { /* imports handled at module level */ }
	else if (k === NodeKind.DecoratedDecl) { genDecoratedDecl(g, node); }
	else if (k === NodeKind.TypeAliasDecl) { /* type aliases are compile-time only */ }
	else if (k === NodeKind.ExternDecl) { /* extern declarations handled in types/headers */ }
	else {
		// Statement or variable at top level
		genTopLevelStmt(g, node);
	}
}

// ===== Function Declaration =====

function genFunctionDecl(g: CGen, node: Node): void {
	const d = node.data as FunctionDeclData;
	const name = safeName(d.fnName);

	// Skip if already declared
	if (nameSetHas(g.declaredProcs, name)) return;
	nameSetAdd(g.declaredProcs, name);

	// Determine C return type from annotation
	const cRetType = mapTypeAnnotation(d.fnReturnType);

	// Build parameter list
	let paramList = "";
	let i = 0;
	while (i < d.params.length) {
		if (i > 0) paramList = paramList + ", ";
		const pType = mapParamType(d.fnParamTypes, i);
		paramList = paramList + pType + " " + safeName(d.params[i]);
		i += 1;
	}
	if (d.params.length === 0) paramList = "void";

	// Emit prototype to ProcHeaders
	const proto = cRetType + " " + name + "(" + paramList + ")";
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	// Emit function body to Procs
	if (d.fnBody !== null) {
		const p = createProc(name, null as unknown as Type);
		genStmt(g, p, d.fnBody);
		const locals = readProcLocals(p);
		const stmts = readProcStmts(p);
		const procs = sec(g, CSection.Procs);
		addLine(procs, proto + " {");
		if (locals.length > 0) {
			add(procs, locals);
		}
		add(procs, stmts);
		addLine(procs, "}");
		addNewline(procs);
	}
}

// ===== Enum Declaration =====

function genEnumDecl(g: CGen, node: Node): void {
	const d = node.data as EnumDeclData;
	const name = mangleTypeName(d.enumName);

	// Skip if already declared
	if (nameSetHas(g.declaredThings, name)) return;
	nameSetAdd(g.declaredThings, name);

	// Emit as typedef + #define constants
	const types = sec(g, CSection.Types);
	addLine(types, "typedef int32_t " + name + ";");
	let i = 0;
	while (i < d.enumMembers.length) {
		addLine(types, "#define " + name + "_" + d.enumMembers[i] + " (((" + name + ")" + i + "))");
		i += 1;
	}
	addNewline(types);
}

// ===== Interface Declaration (struct) =====

function genInterfaceDecl(g: CGen, node: Node): void {
	const d = node.data as InterfaceDeclData;

	const name = mangleTypeName(d.interfaceName);

	if (nameSetHas(g.declaredThings, name)) return;
	nameSetAdd(g.declaredThings, name);

	// Forward declaration
	addLine(sec(g, CSection.ForwardDecls), "typedef struct " + name + " " + name + ";");

	// Full struct definition
	const types = sec(g, CSection.Types);
	addLine(types, "struct " + name + " {");
	let i = 0;
	while (i < d.interfaceFields.length) {
		const fieldName = mangleFieldName(d.interfaceFields[i]);
		const fieldType = mapTypeAnnotation(d.interfaceFieldTypes[i]);
		addLine(types, "  " + fieldType + " " + fieldName + ";");
		i += 1;
	}
	addLine(types, "};");
	addNewline(types);
}

// ===== Class Declaration =====

function genClassDecl(g: CGen, node: Node): void {
	const d = node.data as ClassDeclData;

	const name = mangleTypeName(d.className);

	if (nameSetHas(g.declaredThings, name)) return;
	nameSetAdd(g.declaredThings, name);

	// Forward declaration
	addLine(sec(g, CSection.ForwardDecls), "typedef struct " + name + " " + name + ";");

	// Struct with refcount header
	const types = sec(g, CSection.Types);
	addLine(types, "struct " + name + " {");
	addLine(types, "  int32_t _rc;");
	// Emit properties from classBody
	let i = 0;
	while (i < d.classBody.length) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			const fieldType = mapTypeAnnotation(pd.propType);
			const fieldName = mangleFieldName(pd.propName);
			addLine(types, "  " + fieldType + " " + fieldName + ";");
		}
		i += 1;
	}
	addLine(types, "};");
	addNewline(types);

	// Emit methods as free functions with first param being the class pointer
	i = 0;
	while (i < d.classBody.length) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.MethodDecl) {
			genMethodAsFunction(g, member, name);
		} else if (member.kind === NodeKind.ConstructorDecl) {
			genConstructor(g, member, name);
		}
		i += 1;
	}
}

// ===== Method as Free Function =====

function genMethodAsFunction(g: CGen, node: Node, className: string): void {
	const d = node.data as MethodDeclData;
	const methodName = className + "_" + safeName(d.methodName);
	const cRetType = mapTypeAnnotation(d.methodReturnType);

	// Build params: (ClassName* self, ...)
	let paramList = className + "* self";
	let i = 0;
	while (i < d.methodParams.length) {
		paramList = paramList + ", ";
		const pType = mapParamType(d.methodParamTypes, i);
		paramList = paramList + pType + " " + safeName(d.methodParams[i]);
		i += 1;
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

	// Build params
	let paramList = "";
	let i = 0;
	while (i < d.ctorParams.length) {
		if (i > 0) paramList = paramList + ", ";
		const pType = mapParamType(d.ctorParamTypes, i);
		paramList = paramList + pType + " " + safeName(d.ctorParams[i]);
		i += 1;
	}
	if (d.ctorParams.length === 0) paramList = "void";

	const proto = className + "* " + ctorName + "(" + paramList + ")";
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	if (d.ctorBody !== null) {
		const p = createProc(ctorName, null as unknown as Type);
		genStmt(g, p, d.ctorBody);
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

// ===== Export Declaration =====

function genExportDecl(g: CGen, node: Node): void {
	const d = node.data as ExportDeclData;
	// In C backend, exports are just declarations (no export keyword)
	genDecl(g, d.exportedDecl);
}

// ===== Decorated Declaration =====

function genDecoratedDecl(g: CGen, node: Node): void {
	const d = node.data as DecoratedDeclData;
	// Skip decorators, emit inner declaration
	genDecl(g, d.decoratedNode);
}

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
	const cType = mapTypeAnnotation(d.declType);

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

// ===== Type annotation mapping =====

export function mapTypeAnnotation(annotation: string): string {
	if (annotation === "") return "double";
	if (annotation === "number") return "double";
	if (annotation === "float64") return "double";
	if (annotation === "int32") return "int32_t";
	if (annotation === "int64") return "int64_t";
	if (annotation === "uint32") return "uint32_t";
	if (annotation === "float32") return "float";
	if (annotation === "boolean") return "NIM_BOOL";
	if (annotation === "string") return "msString";
	if (annotation === "void") return "void";
	return "void*";
}

function mapParamType(paramTypes: string[], idx: number): string {
	if (idx < paramTypes.length) return mapTypeAnnotation(paramTypes[idx]);
	return "void*";
}

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
	let i = 0;
	while (i < pd.programStmts.length) {
		genDecl(g, pd.programStmts[i]);
		i += 1;
	}
	return assembleOutput(g);
}

testGroup("C Decl Function", () => {
	test("simple function", () => {
		const result = declOutput("function foo(): void { return; }");
		check(result.length > 0);
		// Should have prototype and body
	});
	test("function with params", () => {
		const result = declOutput("function add(a: number, b: number): number { return a + b; }");
		check(result.length > 0);
	});
});

testGroup("C Decl Enum", () => {
	test("simple enum", () => {
		const result = declOutput("enum Color { Red, Green, Blue }");
		check(result.length > 0);
	});
});

testGroup("C Decl Interface", () => {
	test("simple interface", () => {
		const result = declOutput("interface Point { x: number; y: number; }");
		check(result.length > 0);
	});
});

testGroup("C Decl Export", () => {
	test("exported function", () => {
		const result = declOutput("export function bar(): void { return; }");
		check(result.length > 0);
	});
});

testGroup("C Decl GlobalVar", () => {
	test("const global", () => {
		const result = declOutput("const x: number = 42;");
		check(result.length > 0);
	});
});

