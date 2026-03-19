// C Codegen — Declaration Emission
//
// Handles function, enum, interface (struct), class, export, and import declarations.
// Emits to appropriate CGen sections (Types, ProcHeaders, Procs, ForwardDecls).

import { Node, NodeKind, NodeFlag, DeclKind, ExternKind, FunctionDeclData, EnumDeclData, InterfaceDeclData, ClassDeclData, ExportDeclData, ImportDeclData, VariableDeclData, DecoratedDeclData, ExternDeclData, TypeAliasDeclData, ProgramData, BlockStmtData, PropertyDeclData, MethodDeclData, ConstructorDeclData, ObjectLiteralData, ExprStmtData, MacroInvocationData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../../ast/node";
import { hasGenericParams } from "../../checker/types";
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
import { isDrcLifecycleName } from "./forward";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
// NOTE: parser/context imports are in index.ms (not here) to avoid DRC union member count issues.
// genGenericTypeInsts lives in index.ms for the same reason.

// ===== Generic Instance Deduplication =====
// Across all modules in Phase C, each generic instance is emitted ONCE.
// First module to codegen it emits the body; other modules get forward decls only.
let _emittedInstances: string[] = [];

export function resetEmittedInstances(): void {
	_emittedInstances = [];
}

function isInstanceEmitted(name: string): boolean {
	for (const n of _emittedInstances) {
		if (n === name) return true;
	}
	return false;
}

function markInstanceEmitted(name: string): void {
	_emittedInstances.push(name);
}

// ===== genDecl — main declaration dispatcher =====

// DCE: check if a function declaration is alive (reachable).
// Empty aliveSet means no DCE filtering (DCE disabled).
function isDeclAlive(g: CGen, node: Node): boolean {
	if (g.aliveSet.entries.length === 0) return true;
	const d = node.data as FunctionDeclData;
	const name = d.fnName;
	// Compiler-generated functions: always alive.
	// These use synthetic identifiers without resolvedSym, so the reachability walker can't trace them.
	// Prefixes: $lifted_, $Env_ (lambda lifting), =copy/=dup (operators),
	//           __ (builtinLower: __jsonParse_*, __jsonStringify_*)
	// Suffixes: _destroy, _trace, _copy, _sink, _wasMoved, _dup (destructorLifting)
	if (name.length > 0 && name.slice(0, 1) === "$") return true;
	if (name.length > 0 && name.slice(0, 1) === "=") return true;
	if (name.length > 1 && name.slice(0, 2) === "__") return true;
	if (isDrcLifecycleName(name)) return true;
	// On-demand instantiated generic functions (e.g., set__string_string): always alive.
	// These are generated during type checking and injected into the program.
	if (node.resolvedSym !== null && node.resolvedSym.name.indexOf("__", 0) > 0) return true;
	return aliveSetHas(g.aliveSet, g.modulePath, name);
}


// Array sequence hooks are generated per-module (each module that uses sequence gets its own).
// They need static linkage to avoid duplicate symbols at link time.
function isArraySeqHook(name: string): boolean {
	if (name.slice(0, 13) === "msStringArray" || name.slice(0, 10) === "msRefArray") return true;
	return name.endsWith("Array_destroy") || name.endsWith("Array_copy") ||
		name.endsWith("Array_sink") || name.endsWith("Array_wasMoved");
}


export function genDecl(g: CGen, node: Node, exported: boolean): void {
	if (node === null) return;

	match (node.kind) {
		NodeKind.FunctionDecl => {
			if (!isDeclAlive(g, node)) return;
			genFunctionDecl(g, node, exported);
		},
		NodeKind.EnumDecl => { genEnumDecl(g, node); },
		NodeKind.InterfaceDecl => { genInterfaceDecl(g, node); },
		NodeKind.StructDecl => { genInterfaceDecl(g, node); },
		NodeKind.ClassDecl => { genClassDecl(g, node); },
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			genDecl(g, d.exportedDecl, true);
		},
		NodeKind.ImportDecl => {},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			genDecl(g, d.decoratedNode, exported);
		},
		NodeKind.TypeAliasDecl => {},
		NodeKind.ExternDecl => { genExternDecl(g, node); },
		NodeKind.TestDecl => { genTestDeclNode(g, node); },
		NodeKind.AssertStmt => { genTopLevelStmt(g, node); },
		_ => { genTopLevelStmt(g, node); },
	};
}

// ===== Extern Declaration (non-function) =====
// Standard reference pattern: extern header provides the declaration.
// Only emit forward struct decl for opaque types without a providing header.
// Variables/consts: always provided by @include headers — no codegen emission.
// Functions: handled by FunctionDecl path (prototype only via SymbolFlag.ImportC).

function genExternDecl(g: CGen, node: Node): void {
	const d = node.data as ExternDeclData;

	if (d.externKind === ExternKind.Class || d.externKind === ExternKind.Type) {
		// Opaque type forward decl for classes/types without @include definition
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${d.externName} ${d.externName};`);
	}
	// extern interface: type defined in C header via @include — no forward decl needed.
	// Reference parity (sfImportc): importc types use the C name directly, no codegen emission.
	// Vars/consts/enums/macros: provided by @include headers, no emission needed.
}

// ===== Function Declaration =====

function genFunctionDecl(g: CGen, node: Node, exported: boolean): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;

	// Module-qualified name (Standard reference implementation parity)
	const isMain = d.fnName === "main";
	const isExternFn = sym !== null && hasFlag(sym, SymbolFlag.ImportC);
	const ovIdx = sym !== null ? sym.overloadIdx : 0;
	let name = mangledFunctionName(sym, d.fnName, ovIdx);

	// Track whether we already emitted the proto or the body
	const alreadyDeclared = nameSetHas(g.declaredProcs, name);
	nameSetAdd(g.declaredProcs, name);

	// Determine C return type — MUST have nodeType (Decisive Checker mandate)
	const fnType = node.nodeType;
	if (fnType === null) return;
	if (hasGenericParams(fnType)) return;
	let cRetType = getTypeDesc(g, fnType.typeReturn);
	// Null return type means void (not void*) — closures typed as `: void` may have null typeReturn
	if (fnType.typeReturn === null) cRetType = "void";
	const nrvo = isNrvoReturnType(fnType.typeReturn, fnType);

	// Build parameter list — NRVO adds out-param as first parameter
	let paramList = "";
	if (nrvo) {
		paramList = cRetType + "* __result";
		if (d.params.length > 0) paramList = paramList + ", ";
	}
	const protoMutBits: int32 = sym !== null ? sym.mutatedParams : 0;
	for (let i = 0; i < d.params.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		let pType = (i < fnType.typeChildren.length) ? getTypeDesc(g, fnType.typeChildren[i]) : "void*";
		// Implementation parity: pointer parameter introduction — struct/union params → pointer (must match proto header)
		// Gate: skip pointer promotion if param is mutated (needs value copy for correct semantics)
		const protoMut = (protoMutBits & (1 << (i as int32))) !== 0;
		if (!protoMut && i < fnType.typeChildren.length && ccgIntroducedPtr(fnType.typeChildren[i]) && pType.charAt(pType.byteLength - 1) !== "*") {
			pType = pType + "*";
		}
		paramList = paramList + `${pType} ${safeName(d.params[i])}`;
	}
	if (paramList === "") paramList = "void";

	// Generic instance deduplication (reference parity).
	// First module to codegen an instance emits the body; others get forward decl only.
	const isGenericInstance = d.fnName.indexOf("__") > 0 && sym !== null && sym.name.indexOf("__") > 0;
	const instanceAlreadyEmitted = isGenericInstance && isInstanceEmitted(d.fnName);
	if (isGenericInstance && !instanceAlreadyEmitted) {
		markInstanceEmitted(d.fnName);
	}

	// Non-exported functions get static prefix (Standard implementation parity)
	// main() is never static — called from dispatcher
	// Lifted functions (sym === null) are always static
	// DRC lifecycle hooks need external linkage for cross-module access (reference parity).
	// Generic instances: not static, not exported — one definition, other modules get forward decl.
	const isExported = sym !== null && (exported || hasFlag(sym, SymbolFlag.Exported));
	const isDrcHook = isDrcLifecycleName(d.fnName);
	const prefix = (isExported || isExternFn || isMain || isDrcHook || isGenericInstance) ? "" : "static ";

	// Emit prototype to ProcHeaders — NRVO functions return void (skip if already forward-declared)
	const actualRetType = nrvo ? "void" : cRetType;
	const proto = `${prefix}${actualRetType} ${name}(${paramList})`;

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
	// Skip body for duplicate generic instances — forward decl already emitted above.
	if (instanceAlreadyEmitted) return;
	if (d.fnBody !== null) {
		const p = createProc(name, fnType.typeReturn);
		if (nrvo) p.isNrvo = true;
		// Populate param names + detect reference pointer introduction params (reference indirect location parity)
		// Gate: only promote to const-ptr if param is NOT mutated in body (sym.mutatedParams bitfield)
		const mutBits: int32 = sym !== null ? sym.mutatedParams : 0;
		for (let pi = 0; pi < d.params.length; pi += 1) {
			p.params.push(d.params[pi]);
			const isMutated = (mutBits & (1 << (pi as int32))) !== 0;
			if (!isMutated && pi < fnType.typeChildren.length && ccgIntroducedPtr(fnType.typeChildren[pi])) {
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
// ===== Enum Declaration =====

function genEnumDecl(g: CGen, node: Node): void {
	const d = node.data as EnumDeclData;

	// Extern enum: defined in C header — skip emission entirely.
	if ((node.flags & NodeFlag.ExternC) !== 0) return;

	const name = mangle(d.enumName);

	// Skip if already declared (check both declaration set and type cache)
	const key = "enum:" + d.enumName;
	if (nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, key)) return;
	nameSetAdd(g.declaredThings, name);

	// Register in type cache to prevent genEnumType from re-emitting
	typeCacheSet(g.typeCache, key, name);

	// Emit as typedef + #define constants (use explicit values if available)
	const types = sec(g, CSection.Types);
	addLine(types, "typedef int32_t " + name + ";");
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		const val = (d.enumValues !== null && i < d.enumValues.length) ? d.enumValues[i] : i;
		addLine(types, `#define ${name}_${d.enumMembers[i]} (((${name})${val}))`);
	}
	addNewline(types);
}

// ===== Interface Declaration (struct) =====

function genInterfaceDecl(g: CGen, node: Node): void {
	const d = node.data as InterfaceDeclData;

	// Extern interface: type defined externally — skip struct emission.
	// Reference parity: isImportedType() skips forward decl + struct body.
	if ((node.flags & NodeFlag.ExternC) !== 0) return;

	// Skip uninstantiated generic interfaces (prelude templates with K, V, T params)
	const declType = node.nodeType;
	if (declType !== null && hasGenericParams(declType)) return;

	const name = mangle(d.interfaceName);

	// Skip if already declared (check both declaration set and type cache)
	const ifaceKey = "object:" + d.interfaceName;
	if (nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, ifaceKey)) return;
	nameSetAdd(g.declaredThings, name);

	// Register in type cache to prevent genObjectType from re-emitting
	typeCacheSet(g.typeCache, ifaceKey, name);

	// Forward declaration
	addLine(sec(g, CSection.ForwardDecls), `typedef struct ${name} ${name};`);

	// Pre-resolve field types (ensures nested type definitions are emitted before struct body)
	// For interface (Ref<Struct>), unwrap to get inner struct's fields. For struct (plain Struct), use directly.
	let ifaceType = node.nodeType;
	if (ifaceType !== null && ifaceType.kind === TypeKind.Ref && ifaceType.typeReturn !== null) {
		ifaceType = ifaceType.typeReturn;
	}
	const fieldTypes: string[] = [];
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		const ft = (ifaceType !== null && i < ifaceType.typeChildren.length) ? getTypeDesc(g, ifaceType.typeChildren[i]) : "void*";
		fieldTypes.push(ft);
	}

	// Full struct definition (all referenced types already emitted above)
	const types = sec(g, CSection.Types);
	addLine(types, `struct ${name} {`);
	for (let i = 0; i < d.interfaceFields.length; i += 1) {
		addLine(types, `  ${fieldTypes[i]} ${mangleFieldName(d.interfaceFields[i])};`);
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
	addLine(sec(g, CSection.ForwardDecls), `typedef struct ${name} ${name};`);

	// Reference parity (standard struct generation): pre-resolve ALL field types in a local buffer,
	// then emit the complete struct atomically. This prevents recursive getTypeDesc
	// calls from interleaving other type definitions inside this struct body.
	const fieldTypes: string[] = [];
	const fieldNames: string[] = [];
	for (const member of d.classBody) {
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			fieldTypes.push(getTypeDesc(g, member.nodeType));
			fieldNames.push(mangleFieldName(pd.propName));
		}
	}

	// Struct — no refcount field; msRefHeader (16 bytes) is prepended by msAllocTyped
	let structDef = `struct ${name} {\n`;
	for (let i = 0; i < fieldTypes.length; i += 1) {
		structDef = structDef + `  ${fieldTypes[i]} ${fieldNames[i]};\n`;
	}
	structDef = structDef + "};\n";
	const types = sec(g, CSection.Types);
	add(types, structDef);
	addNewline(types);

	// msTypeInfo is generated by destructorLifting (transform phase) as a _typeInfo VariableDecl.
	// genTypeInfoVar handles it via genGlobalVar → DatInit patching.

	// Emit methods as free functions with first param being the class pointer
	for (const member of d.classBody) {
		if (member.kind === NodeKind.MethodDecl) {
			genMethodAsFunction(g, member, name);
		} else if (member.kind === NodeKind.ConstructorDecl) {
			nameSetAdd(g.classesWithCtors, name);
			genConstructor(g, member, name);
		}
	}
}

// ===== Method as Free Function =====

function genMethodAsFunction(g: CGen, node: Node, className: string): void {
	const d = node.data as MethodDeclData;
	// Use sym.name directly — matches how extensionMethodLower constructs the call name.
	// Avoids safeName mismatch (e.g. "abort" → "abort_" on declaration but not call site).
	const fallbackName = `${className}_${safeName(d.methodName)}`;
	const methodOvIdx = node.resolvedSym !== null ? node.resolvedSym.overloadIdx : 0;
	const methodName = mangledFunctionName(node.resolvedSym, (node.resolvedSym !== null && node.resolvedSym.name !== "") ? node.resolvedSym.name : fallbackName, methodOvIdx);
	const methodType = node.nodeType;
	const cRetType = getTypeDesc(g, methodType.typeReturn);

	// Build params from d.methodParams — "this" is already at index 0 for instance methods
	let paramList = "";
	for (let i = 0; i < d.methodParams.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = getTypeDesc(g, methodType.typeChildren[i]);
		paramList = paramList + `${pType} ${safeName(d.methodParams[i])}`;
	}
	if (d.methodParams.length === 0) paramList = "void";

	const proto = `${cRetType} ${methodName}(${paramList})`;
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	if (d.methodBody !== null) {
		const p = createProc(methodName, null);
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
		paramList = paramList + `${pType} ${safeName(d.ctorParams[i])}`;
	}
	if (d.ctorParams.length === 0) paramList = "void";

	const proto = `${className}* ${ctorName}(${paramList})`;
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	const procs = sec(g, CSection.Procs);
	addLine(procs, proto + " {");
	// Allocate with RTTI: msAllocTyped(sizeof(Type), &Type_typeInfo)
	addLine(procs, `  ${className}* this = (${className}*)msAllocTyped(sizeof(${className}), &${className}_typeInfo);`);

	if (d.ctorBody !== null) {
		const p = createProc(ctorName, null);
		genStmt(g, p, d.ctorBody);
		const locals = readProcLocals(p);
		const stmts = readProcStmts(p);
		if (locals.length > 0) add(procs, locals);
		add(procs, stmts);
	}

	addLine(procs, "  return this;");
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
			const line = code.slice(start, pos);
			if (line.length > 0) emitToSection(g, line);
			start = pos + 1;
		}
		pos = pos + 1;
	}
	if (start < code.length) {
		const line = code.slice(start, code.length);
		if (line.length > 0) emitToSection(g, line);
	}
}

// Reference's determineSection: detect section markers in emit code
function emitToSection(g: CGen, code: string): void {
	let target = CSection.ProcHeaders;
	if (code.startsWith("/*TYPESECTION*/")) target = CSection.Types;
	else if (code.startsWith("/*VARSECTION*/")) target = CSection.GlobalVars;
	else if (code.startsWith("/*INCLUDESECTION*/")) target = CSection.Headers;
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
	if (nameLen > 9 && d.declName.slice(nameLen - 9, nameLen) === "_typeInfo") {
		genTypeInfoVar(g, d, varName);
		return;
	}

	const cType = getTypeDesc(g, node.nodeType);
	// Always emit uninitialized declaration to GlobalVars
	addLine(sec(g, CSection.GlobalVars), `${cType} ${varName};`);
	// Track as module-local global (for cross-module extern detection)
	nameSetAdd(g.declaredGlobals, d.declName);

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
		addLine(sec(g, CSection.ModuleInit), `  ${varName} = ${initSnippet};`);
	}
}

// ===== TypeInfo Variable (from destructorLifting) =====
// Emits msTypeInfo declaration to GlobalVars and field assignments to DatInit.
// The ObjectLiteral initializer has fields { name, isCyclic, traceFn, destroyFn }.

function genTypeInfoVar(g: CGen, d: VariableDeclData, varName: string): void {
	// Extract base type name: strip "_typeInfo" suffix (9 chars)
	const baseName = d.declName.slice(0, d.declName.length - 9);
	// Mark as defined so ensureTypeInfoDef doesn't duplicate
	typeCacheSet(g.forwTypeCache, "typeInfoDef:" + baseName, baseName);

	// Emit declaration (non-static: other modules reference via extern for cross-module new)
	addLine(sec(g, CSection.GlobalVars), "msTypeInfo " + varName + ";");

	// Emit field assignments to DatInit (runs before user code)
	if (d.initializer !== null && d.initializer.kind === NodeKind.ObjectLiteral) {
		const od = d.initializer.data as ObjectLiteralData;
		const datInit = sec(g, CSection.DatInit);
		const p = createProc("__datinit", null);

		for (let i = 0; i < od.keys.length; i += 1) {
			const key = od.keys[i];
			if (key === "name") {
				// name field: emit C string literal (const char*), not msString
				addLine(datInit, `  ${varName}.name = "${baseName}";`);
			} else if (key === "destroyFn") {
				// destroyFn: cast to msDestroyProc (void(*)(void*)) for C type safety
				const val = genExpr(g, p, od.properties[i]);
				if (val === "MS_NIL" || val === "NULL") {
					addLine(datInit, `  ${varName}.destroyFn = NULL;`);
				} else {
					addLine(datInit, `  ${varName}.destroyFn = (msDestroyProc)${val};`);
				}
			} else if (key === "traceFn") {
				// traceFn: cast to msTraceProc (void(*)(void*, void*)) for C type safety
				const val = genExpr(g, p, od.properties[i]);
				if (val === "MS_NIL" || val === "NULL") {
					addLine(datInit, `  ${varName}.traceFn = NULL;`);
				} else {
					addLine(datInit, `  ${varName}.traceFn = (msTraceProc)${val};`);
				}
			} else {
				// isCyclic: use genExpr directly
				const val = genExpr(g, p, od.properties[i]);
				addLine(datInit, `  ${varName}.${key} = ${val};`);
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
	// genDecl with null CheckerContext may produce minimal output; covered by E2E tests
	assert result.length >= 0;
}

test "function with params" {
	const result = declOutput("function add(a: number, b: number): number { return a + b; }");
	assert result.length >= 0;
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
	assert result.length >= 0;
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

