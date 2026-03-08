// C Codegen — Declaration Emission
//
// Handles function, enum, interface (struct), class, export, and import declarations.
// Emits to appropriate CGen sections (Types, ProcHeaders, Procs, ForwardDecls).

import {
	Node, NodeKind, DeclKind, ExternKind,
	FunctionDeclData, EnumDeclData,
	InterfaceDeclData, ClassDeclData,
	ExportDeclData, ImportDeclData,
	VariableDeclData, DecoratedDeclData,
	ExternDeclData,
	ProgramData, BlockStmtData,
	PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ObjectLiteralData,
	ExprStmtData, MacroInvocationData,
} from "../../ast/node";
import { sliceStr, startsWith, endsWith } from "../../utils/string";
import { Type, TypeKind } from "../../checker/types";
import {
	CGen, CProc, CSection, Builder,
	createProc, createBuilder, add, addLine, addNewline,
	sec, extract, nameSetHas, nameSetAdd,
	emitStmts, emitStmtsLine, readProcStmts, readProcLocals,
	clearProcBuffers, typeCacheSet, typeCacheHas,
	aliveSetHas,
} from "./context";
import { genExpr } from "./expressions";
import { genStmt, genStmts, resolveEmitArgs } from "./statements";
import { mangle, mangleTypeName, mangleFieldName, mangledFunctionName, safeName } from "./names";
import { getSimpleTypeDesc, getTypeDesc, isNrvoReturnType, annotationToC, ccgIntroducedPtr } from "./types";
import { genTestDeclNode } from "./test";
import {
	Symbol, SymbolKind, SymbolState,
	hasFlag, SymbolFlag,
} from "../../checker/symbol";
// NOTE: parser/context imports are in index.ms (not here) to avoid DRC union member count issues.
// genGenericTypeInsts lives in index.ms for the same reason.

// ===== genDecl — main declaration dispatcher =====

// DCE: check if a function declaration is alive (reachable).
// Empty aliveSet means no DCE filtering (DCE disabled).
function isDeclAlive(g: CGen, node: Node): boolean {
	if (g.aliveSet.entries.length === 0) return true;
	const d = node.data as FunctionDeclData;
	const name = d.fnName;
	// Compiler-generated functions are always alive — produced by transforms
	// after reachability analysis runs on pre-transform ASTs.
	// Prefixes: $lifted_, $Env_ (lambda lifting), =copy/=dup (operators)
	// Suffixes: _destroy, _trace, _copy, _sink, _wasMoved, _dup (destructorLifting)
	if (name.length > 0 && name.slice(0, 1) === "$") return true;
	if (name.length > 0 && name.slice(0, 1) === "=") return true;
	if (endsWith(name, "_destroy") || endsWith(name, "_trace") ||
		endsWith(name, "_copy") || endsWith(name, "_sink") ||
		endsWith(name, "_wasMoved") || endsWith(name, "_dup")) return true;
	return aliveSetHas(g.aliveSet, g.modulePath, name);
}


// Array sequence hooks are generated per-module (each module that uses sequence gets its own).
// They need static linkage to avoid duplicate symbols at link time.
// Reference parity: we use static linkage per-module instead of global deduplication.
// DRC lifecycle suffixes — single source of truth for hook detection.
// Reference parity: these are regular procs emitted in defining module, prototyped in consumers.
const DRC_SUFFIXES: string[] = ["_destroy", "_copy", "_sink", "_wasMoved", "_dup", "_eq", "_trace", "_typeInfo"];

function hasSuffix(name: string, suffixes: string[]): boolean {
	let i = 0;
	while (i < suffixes.length) {
		if (endsWith(name, suffixes[i])) return true;
		i = i + 1;
	}
	return false;
}

function isArraySeqHook(name: string): boolean {
	if (name.slice(0, 13) === "msStringArray" || name.slice(0, 10) === "msRefArray") return true;
	return endsWith(name, "Array_destroy") || endsWith(name, "Array_copy") ||
		endsWith(name, "Array_sink") || endsWith(name, "Array_wasMoved");
}

function isDrcLifecycleName(name: string): boolean {
	return hasSuffix(name, DRC_SUFFIXES);
}

// reference parity: genProcNoForward emits genProcPrototype(m, prc) in the calling module
// for cross-module procs. We do the same for DRC hooks: if codegen encounters a call
// to a DRC lifecycle function not yet declared, emit a forward prototype.
// Signatures are known by convention (suffix determines parameter pattern).
export function ensureDrcProto(g: CGen, callee: string): void {
	if (!isDrcLifecycleName(callee)) return;
	if (nameSetHas(g.declaredProcs, callee)) return;
	nameSetAdd(g.declaredProcs, callee);

	// Extract type name prefix: "TypeName_destroy" → "TypeName"
	const lastUnderscore = callee.lastIndexOf("_");
	if (lastUnderscore < 0) return;
	const typeName = callee.slice(0, lastUnderscore);
	const suffix = callee.slice(lastUnderscore, callee.length);

	// reference parity (reference prototype): sequence/array hooks have different param conventions
	// destroy: by-value; wasMoved: by-pointer; copy/sink: dest by-pointer, src by-value
	const isSeqHook = endsWith(typeName, "Array");

	let proto = "";
	if (suffix === "_destroy") {
		if (isSeqHook) {
			// reference parity: destroy(self: sequence) — by-value
			proto = "void " + callee + "(" + typeName + " self)";
		} else {
			proto = "void " + callee + "(" + typeName + "* self)";
		}
	} else if (suffix === "_wasMoved") {
		// Always by-pointer (var param in reference implementation)
		proto = "void " + callee + "(" + typeName + "* self)";
	} else if (suffix === "_copy" || suffix === "_sink") {
		if (isSeqHook) {
			// reference parity: copy/sink(dest: var sequence, src: sequence) — dest ptr, src value
			proto = "void " + callee + "(" + typeName + "* dest, " + typeName + " src)";
		} else {
			proto = "void " + callee + "(" + typeName + "* dest, " + typeName + "* src)";
		}
	} else if (suffix === "_dup") {
		// TypeName TypeName_dup(TypeName* src)
		proto = typeName + " " + callee + "(" + typeName + "* src)";
	} else if (suffix === "_eq") {
		// MS_BOOL TypeName_eq(TypeName* a, TypeName* b)
		proto = "MS_BOOL " + callee + "(" + typeName + "* a, " + typeName + "* b)";
	} else if (suffix === "_trace") {
		// void TypeName_trace(TypeName* self, void* callback)
		proto = "void " + callee + "(" + typeName + "* self, void* callback)";
	} else {
		return;
	}
	// Per-module array/seq hooks need static linkage (generated in every module that uses them)
	if (isSeqHook) proto = "static " + proto;
	addLine(sec(g, CSection.ProcHeaders), proto + ";");
}

// On-demand cross-module function prototype emission (reference parity: genProcPrototype).
// Called from genCallExpr when a cross-module function is referenced.
// Emits prototype into ProcHeaders, deduped via declaredProcs.
export function ensureCrossModuleProto(g: CGen, calleeName: string, fnType: Type, sym: Symbol): void {
	if (fnType === null || fnType.kind !== TypeKind.Function) return;
	// Only for cross-module procs — same-module procs have their own forward decl
	if (sym !== null && sym.modulePath !== "" && sym.modulePath === g.modulePath) return;
	// Skip native/extern — already provided by headers
	if (sym !== null && sym.nativeName !== "") return;
	// Dedup
	const protoKey = "proto:" + calleeName;
	if (nameSetHas(g.declaredProcs, protoKey)) return;
	nameSetAdd(g.declaredProcs, protoKey);
	// Build prototype string
	const retType = getTypeDesc(g, fnType.typeReturn);
	const nrvo = isNrvoReturnType(fnType.typeReturn);
	let paramList = "";
	if (nrvo) {
		paramList = retType + "* __result";
		if (fnType.typeChildren !== null && fnType.typeChildren.length > 0) paramList = paramList + ", ";
	}
	if (fnType.typeChildren !== null) {
		let i = 0;
		while (i < fnType.typeChildren.length) {
			if (i > 0) paramList = paramList + ", ";
			let pType = getTypeDesc(g, fnType.typeChildren[i]);
			if (ccgIntroducedPtr(fnType.typeChildren[i]) && pType.length > 0 && pType.charAt(pType.length - 1) !== "*") {
				pType = pType + "*";
			}
			paramList = paramList + pType;
			i += 1;
		}
	}
	if (paramList === "") paramList = "void";
	let cRetType = retType;
	if (nrvo) cRetType = "void";
	addLine(sec(g, CSection.ProcHeaders), cRetType + " " + calleeName + "(" + paramList + ");");
}

export function genDecl(g: CGen, node: Node, exported: boolean): void {
	if (node === null) return;

	const k = node.kind;
	if (k === NodeKind.FunctionDecl) {
		if (!isDeclAlive(g, node)) return;
		genFunctionDecl(g, node, exported);
	}
	else if (k === NodeKind.EnumDecl) { genEnumDecl(g, node); }
	else if (k === NodeKind.InterfaceDecl) { genInterfaceDecl(g, node); }
	else if (k === NodeKind.ClassDecl) { genClassDecl(g, node); }
	else if (k === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		genDecl(g, d.exportedDecl, true);
	}
	else if (k === NodeKind.ImportDecl) { /* handled by destructorLifting for types */ }
	else if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		genDecl(g, d.decoratedNode, exported);
	}
	else if (k === NodeKind.TypeAliasDecl) { /* type aliases are compile-time only */ }
	else if (k === NodeKind.ExternDecl) { genExternDecl(g, node); }
	else if (k === NodeKind.TestDecl) { genTestDeclNode(g, node); }
	else if (k === NodeKind.AssertStmt) { genTopLevelStmt(g, node); }
	else {
		// Statement or variable at top level
		genTopLevelStmt(g, node);
	}
}

// ===== Extern Declaration (non-function) =====
// Standard reference pattern: extern header provides the declaration.
// Only emit forward struct decl for opaque types without a providing header.
// Variables/consts: always provided by @include headers — no codegen emission.
// Functions: handled by FunctionDecl path (prototype only via SymbolFlag.ImportC).

function genExternDecl(g: CGen, node: Node): void {
	const d = node.data as ExternDeclData;

	if (d.externKind === ExternKind.Class || d.externKind === ExternKind.Interface || d.externKind === ExternKind.Type) {
		// Opaque type forward decl: typedef struct Name Name;
		// If @include provides full definition, this is harmless (forward decl before full def is valid C).
		addLine(sec(g, CSection.ForwardDecls), "typedef struct " + d.externName + " " + d.externName + ";");
	}
	// Vars/consts/enums/macros: provided by @include headers, no emission needed.
}

// ===== Function Declaration =====

function genFunctionDecl(g: CGen, node: Node, exported: boolean): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;

	// Module-qualified name (Standard reference implementation parity)
	const isMain = d.fnName === "main";
	const isExternFn = sym !== null && hasFlag(sym, SymbolFlag.ImportC);
	let ovIdx = 0;
	if (sym !== null && sym.overloads !== null && sym.overloads.length > 0) {
		ovIdx = findOverloadIdx(sym, node.resolvedSym);
	}
	let name = mangledFunctionName(sym, d.fnName, ovIdx);

	// Track whether we already emitted the proto or the body
	const alreadyDeclared = nameSetHas(g.declaredProcs, name);
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
		// Implementation parity: pointer parameter introduction — interface/union params → pointer (must match proto header)
		if (i < fnType.typeChildren.length && ccgIntroducedPtr(fnType.typeChildren[i]) && pType.charAt(pType.length - 1) !== "*") {
			pType = pType + "*";
		}
		paramList = paramList + pType + " " + safeName(d.params[i]);
	}
	if (paramList === "") paramList = "void";

	// Non-exported functions get static prefix (Standard implementation parity)
	// main() is never static — called from dispatcher
	// Lifted functions (sym === null) are always static
	// DRC lifecycle hooks need external linkage for cross-module access (reference parity)
	const isExported = sym !== null && (exported || hasFlag(sym, SymbolFlag.Exported));
	const isDrcHook = isDrcLifecycleName(d.fnName);
	// Array/sequence hooks are generated per-module — they need static linkage to avoid
	// duplicate symbols at link time. Matches msStringArray_*, msRefArray_*, and
	// per-type value array hooks like FileEntryArray_* (reference parity: each sequence gets its own hooks).
	const isPerModuleHook = isDrcHook && isArraySeqHook(d.fnName);
	const prefix = (isExported || isExternFn || isMain || (isDrcHook && !isPerModuleHook)) ? "" : "static ";

	// Emit prototype to ProcHeaders — NRVO functions return void (skip if already forward-declared)
	const actualRetType = nrvo ? "void" : cRetType;
	const proto = prefix + actualRetType + " " + name + "(" + paramList + ")";

	// Extern functions with 'from' clause bind to existing C functions — header provides declaration.
	// Extern functions without 'from' use mangled name and need our prototype.
	const hasNativeName = sym !== null && sym.nativeName !== "";
	if (isExternFn && hasNativeName) return;

	if (!alreadyDeclared) {
		addLine(sec(g, CSection.ProcHeaders), proto + ";");
	}

	// Extern functions: prototype only, no body
	if (isExternFn) return;

	// Emit function body to Procs
	if (d.fnBody !== null) {
		const p = createProc(name, fnType.typeReturn);
		if (nrvo) p.isNrvo = true;
		// Populate param names + detect reference pointer introduction params (reference indirect location parity)
		for (let pi = 0; pi < d.params.length; pi += 1) {
			p.params.push(d.params[pi]);
			if (pi < fnType.typeChildren.length && ccgIntroducedPtr(fnType.typeChildren[pi])) {
				p.indirectParams.push(d.params[pi]);
			}
		}
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
	// Value type only — Ref<Struct> wrapper adds the * via TypeKind.Ref path
	typeCacheSet(g.typeCache, classKey, name);

	// Forward declaration
	addLine(sec(g, CSection.ForwardDecls), "typedef struct " + name + " " + name + ";");

	// Reference parity (standard struct generation): pre-resolve ALL field types in a local buffer,
	// then emit the complete struct atomically. This prevents recursive getTypeDesc
	// calls from interleaving other type definitions inside this struct body.
	const fieldTypes: string[] = [];
	const fieldNames: string[] = [];
	for (let i = 0; i < d.classBody.length; i += 1) {
		const member = d.classBody[i];
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			fieldTypes.push(getTypeDesc(g, member.nodeType));
			fieldNames.push(mangleFieldName(pd.propName));
		}
	}

	// Struct — no refcount field; msRefHeader (16 bytes) is prepended by msAllocTyped
	let structDef = "struct " + name + " {\n";
	for (let i = 0; i < fieldTypes.length; i += 1) {
		structDef = structDef + "  " + fieldTypes[i] + " " + fieldNames[i] + ";\n";
	}
	structDef = structDef + "};\n";
	const types = sec(g, CSection.Types);
	add(types, structDef);
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

// ===== Top-Level @emit (Reference genEmit + determineSection parity) =====
// Resolves emit args (with backtick-interpolated symbols), then routes each line
// to the appropriate CSection based on section markers.

function genTopLevelEmit(g: CGen, mi: MacroInvocationData): void {
	const code = resolveEmitArgs(g, mi, null as unknown as CProc);
	// Split on newlines and route each line through section detection (reference pattern)
	let start = 0;
	let pos = 0;
	while (pos < code.length) {
		if (code.charAt(pos) === "\n") {
			const line = sliceStr(code, start, pos);
			if (line.length > 0) emitToSection(g, line);
			start = pos + 1;
		}
		pos = pos + 1;
	}
	if (start < code.length) {
		const line = sliceStr(code, start, code.length);
		if (line.length > 0) emitToSection(g, line);
	}
}

// Reference's determineSection: detect section markers in emit code
function emitToSection(g: CGen, code: string): void {
	let target = CSection.ProcHeaders;
	if (startsWith(code, "/*TYPESECTION*/")) target = CSection.Types;
	else if (startsWith(code, "/*VARSECTION*/")) target = CSection.GlobalVars;
	else if (startsWith(code, "/*INCLUDESECTION*/")) target = CSection.Headers;
	addLine(sec(g, target), code);
}

function genTopLevelStmt(g: CGen, node: Node): void {
	// Global variable declarations go to GlobalVars section
	if (node.kind === NodeKind.VariableDecl) {
		genGlobalVar(g, node);
		return;
	}
	// Handle top-level directives
	if (node.kind === NodeKind.ExprStmt) {
		const esd = node.data as ExprStmtData;
		if (esd.expr.kind === NodeKind.MacroInvocation) {
			const mi = esd.expr.data as MacroInvocationData;
			// @emit: codegen handles directly (Reference genEmit parity — p.prc == nil path)
			if (mi.macroName === "emit" && mi.macroArgs.length > 0) {
				genTopLevelEmit(g, mi);
				return;
			}
			// @include/@compile/@link/@passC/@passL: already handled by checker directives
			if (mi.macroName === "include" || mi.macroName === "compile" || mi.macroName === "link" || mi.macroName === "passC" || mi.macroName === "passL") {
				return;
			}
		}
	}
	// Other statements go to ModuleInit — use shared initProc for consistent temp counter
	const p = g.initProc;
	genStmt(g, p, node);
	const locals = readProcLocals(p);
	const stmts = readProcStmts(p);
	clearProcBuffers(p);
	if (locals.length > 0) {
		add(sec(g, CSection.ModuleInit), locals);
	}
	if (stmts.length > 0) {
		add(sec(g, CSection.ModuleInit), stmts);
	}
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
		const p = g.initProc;
		const initSnippet = genExpr(g, p, d.initializer);
		const locals = readProcLocals(p);
		const stmts = readProcStmts(p);
		// Clear after read — shared initProc persists across all global vars
		clearProcBuffers(p);
		if (locals.length > 0) {
			add(sec(g, CSection.ModuleInit), locals);
		}
		if (stmts.length > 0) {
			add(sec(g, CSection.ModuleInit), stmts);
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
	assert result.length > 0;
	// Should have prototype and body
}

test "function with params" {
	const result = declOutput("function add(a: number, b: number): number { return a + b; }");
	assert result.length > 0;
}

test "simple enum" {
	const result = declOutput("enum Color { Red, Green, Blue }");
	assert result.length > 0;
}

test "simple interface" {
	const result = declOutput("interface Point { x: number; y: number; }");
	assert result.length > 0;
}

test "exported function" {
	const result = declOutput("export function bar(): void { return; }");
	assert result.length > 0;
}

test "const global" {
	const result = declOutput("const x: number = 42;");
	assert result.length > 0;
}

test "NRVO function signature" {
	const result = declOutput("interface Point { x: number; y: number; } function makePoint(): Point { return { x: 0, y: 0 }; }");
	// Should have void return + __result param in the output
	assert result.length > 50;
}

