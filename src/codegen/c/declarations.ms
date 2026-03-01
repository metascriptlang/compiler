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
import { Symbol, lookupSymbol, hasOverloads } from "../../checker/symbol";
// NOTE: parser/context imports are in index.ms (not here) to avoid DRC union member count issues.
// genGenericTypeInsts lives in index.ms for the same reason.
import { test, check, testGroup } from "std/testing";

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
	else {
		// Statement or variable at top level
		genTopLevelStmt(g, node);
	}
}

// ===== Function Declaration =====

function genFunctionDecl(g: CGen, node: Node, exported: boolean): void {
	const d = node.data as FunctionDeclData;
	let name = safeName(d.fnName);

	// Overload mangling: if function has overloads, suffix with __idx
	if (g.checkerCtx !== null) {
		const sym = lookupSymbol(g.checkerCtx.table, d.fnName);
		if (sym !== null && hasOverloads(sym)) {
			const idx = findOverloadDeclIndex(sym, node);
			name = safeName(d.fnName) + "__" + idx;
		}
	}

	// Skip if already declared
	if (nameSetHas(g.declaredProcs, name)) return;
	nameSetAdd(g.declaredProcs, name);

	// Determine C return type from annotation
	const cRetType = mapTypeAnnotation(d.fnReturnType);
	const nrvo = isNrvoType(d.fnReturnType);

	// Build parameter list — NRVO adds out-param as first parameter
	let paramList = "";
	if (nrvo) {
		paramList = cRetType + "* __result";
		if (d.params.length > 0) paramList = paramList + ", ";
	}
	for (let i = 0; i < d.params.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = mapParamType(d.fnParamTypes, i);
		paramList = paramList + pType + " " + safeName(d.params[i]);
	}
	if (paramList === "") paramList = "void";

	// Extern functions: emit prototype only, no body (Nim-aligned: importc pragma)
	const isExtern = d.fnFlags === "extern";

	// Non-exported functions get static prefix (better optimization, smaller symbol tables)
	// Extern functions are never static — they link to external C symbols
	const prefix = (exported || isExtern) ? "" : "static ";

	// Emit prototype to ProcHeaders — NRVO functions return void
	const actualRetType = nrvo ? "void" : cRetType;
	const proto = prefix + actualRetType + " " + name + "(" + paramList + ")";
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	// Extern functions: prototype only, no body
	if (isExtern) return;

	// Emit function body to Procs
	if (d.fnBody !== null) {
		const p = createProc(name, null as unknown as Type);
		// Store NRVO flag: use proc name prefix convention
		if (nrvo) {
			p.name = "__nrvo__" + p.name;
		}
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

// ===== Overload Index Matching =====

// Find which overload index this FunctionDecl corresponds to.
// primary = index 0, overloads[0] = index 1, etc.
// Matches by arity + param type comparison using nodeType annotations.
function findOverloadDeclIndex(sym: Symbol, declNode: Node): number {
	const d = declNode.data as FunctionDeclData;
	// Check primary (index 0): match by arity
	if (sym.symbolType.kind === TypeKind.Function) {
		if (matchesDeclToType(declNode, sym.symbolType)) return 0;
	}
	// Check overloads (index 1..n)
	let i = 0;
	while (i < sym.overloads.length) {
		const ovType = sym.overloads[i].symbolType;
		if (ovType.kind === TypeKind.Function) {
			if (matchesDeclToType(declNode, ovType)) return i + 1;
		}
		i = i + 1;
	}
	return 0; // fallback
}

// Check if a FunctionDecl matches a function Type by arity + type annotation names.
function matchesDeclToType(declNode: Node, fnType: Type): boolean {
	const d = declNode.data as FunctionDeclData;
	if (d.params.length !== fnType.typeChildren.length) return false;
	// Compare type annotation strings against resolved type names
	let i = 0;
	while (i < d.params.length) {
		if (i < d.fnParamTypes.length && i < fnType.typeChildren.length) {
			const annot = d.fnParamTypes[i];
			const resolved = fnType.typeChildren[i];
			// Match annotation string against type kind/name
			if (annot !== "" && resolved !== null) {
				if (!annotMatchesType(annot, resolved)) return false;
			}
		}
		i = i + 1;
	}
	return true;
}

// Match a type annotation string (e.g. "number", "string", "Foo") against a resolved Type.
function annotMatchesType(annot: string, t: Type): boolean {
	if (annot === "number" && t.kind === TypeKind.Number) return true;
	if (annot === "string" && t.kind === TypeKind.String) return true;
	if (annot === "boolean" && t.kind === TypeKind.Boolean) return true;
	if (annot === "void" && t.kind === TypeKind.Void) return true;
	if (annot === "int32" && t.kind === TypeKind.Int32) return true;
	if (annot === "int64" && t.kind === TypeKind.Int64) return true;
	if (annot === "float32" && t.kind === TypeKind.Float32) return true;
	if (annot === "float64" && t.kind === TypeKind.Float64) return true;
	if (annot === "uint32" && t.kind === TypeKind.Uint32) return true;
	// Named types: Object, Enum, Distinct — compare typeName
	if (t.typeName !== "" && annot === t.typeName) return true;
	return false;
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
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		addLine(types, "#define " + name + "_" + d.enumMembers[i] + " (((" + name + ")" + i + "))");
	}
	addNewline(types);

	// Generate toString function
	genEnumToString(g, name, d.enumMembers);
}

// ===== Enum toString =====
// Generates: const char* EnumName_toString(EnumName v) { switch(v) { case 0: return "Member"; ... } }

function genEnumToString(g: CGen, name: string, members: string[]): void {
	const fnName = name + "_toString";
	const proto = "const char* " + fnName + "(" + name + " v)";

	// Prototype
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	// Body
	const procs = sec(g, CSection.Procs);
	addLine(procs, proto + " {");
	addLine(procs, "  switch (v) {");
	for (let i = 0; i < members.length; i += 1) {
		addLine(procs, "    case " + i + ": return \"" + members[i] + "\";");
	}
	addLine(procs, "    default: return \"<unknown>\";");
	addLine(procs, "  }");
	addLine(procs, "}");
	addNewline(procs);
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
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		const fieldName = mangleFieldName(d.interfaceFields[i]);
		const fieldType = mapTypeAnnotation(d.interfaceFieldTypes[i]);
		addLine(types, "  " + fieldType + " " + fieldName + ";");
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
	for (let i = 0; i < d.classBody.length; i += 1) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			const fieldType = mapTypeAnnotation(pd.propType);
			const fieldName = mangleFieldName(pd.propName);
			addLine(types, "  " + fieldType + " " + fieldName + ";");
		}
	}
	addLine(types, "};");
	addNewline(types);

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
	const cRetType = mapTypeAnnotation(d.methodReturnType);

	// Build params: (ClassName* self, ...)
	let paramList = className + "* self";
	for (let i = 0; i < d.methodParams.length; i += 1) {
		paramList = paramList + ", ";
		const pType = mapParamType(d.methodParamTypes, i);
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

	// Build params
	let paramList = "";
	for (let i = 0; i < d.ctorParams.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = mapParamType(d.ctorParamTypes, i);
		paramList = paramList + pType + " " + safeName(d.ctorParams[i]);
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

export function mapParamType(paramTypes: string[], idx: number): string {
	if (idx < paramTypes.length) return mapTypeAnnotation(paramTypes[idx]);
	return "void*";
}

// ===== NRVO Detection =====
// Returns true for types that are C structs (passed by value = expensive).
// These get out-param calling convention: void f(RetType* __result, params)

export function isNrvoType(annotation: string): boolean {
	// Primitive types, pointers, void — no NRVO needed
	if (annotation === "" || annotation === "number" || annotation === "float64") return false;
	if (annotation === "int32" || annotation === "int64") return false;
	if (annotation === "uint32" || annotation === "float32") return false;
	if (annotation === "boolean" || annotation === "void") return false;
	if (annotation === "string") return false;  // msString is small (ptr+len), pass by value
	// Named types (interfaces = structs) → NRVO
	return true;
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
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		genDecl(g, pd.programStmts[i], false);
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
	test("enum toString generated", () => {
		const noToStr = declOutput("const x: number = 1;");
		const withToStr = declOutput("enum Color { Red, Green, Blue }");
		// Enum output should be significantly larger due to toString function
		check(withToStr.length > noToStr.length + 50);
	});
	test("enum single member", () => {
		const result = declOutput("enum Single { Only }");
		// Should still generate typedef + toString
		check(result.length > 50);
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

testGroup("C Decl NRVO", () => {
	test("isNrvoType primitives", () => {
		check(!isNrvoType("number"));
		check(!isNrvoType("int32"));
		check(!isNrvoType("boolean"));
		check(!isNrvoType("string"));
		check(!isNrvoType("void"));
		check(!isNrvoType(""));
	});
	test("isNrvoType struct", () => {
		check(isNrvoType("Point"));
		check(isNrvoType("Token"));
	});
	test("NRVO function signature", () => {
		const result = declOutput("interface Point { x: number; y: number; } function makePoint(): Point { return { x: 0, y: 0 }; }");
		// Should have void return + __result param in the output
		check(result.length > 50);
	});
});

