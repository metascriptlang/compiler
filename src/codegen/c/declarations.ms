// C Codegen — Declaration Emission
//
// Handles function, enum, interface (struct), class, export, and import declarations.
// Emits to appropriate CGen sections (Types, ProcHeaders, Procs, ForwardDecls).

import { Node, NodeKind, NodeFlag, ExternKind, FunctionDeclData, EnumDeclData, InterfaceDeclData, ClassDeclData, ExportDeclData, VariableDeclData, DecoratedDeclData, ExternDeclData, ProgramData, PropertyDeclData, ObjectLiteralData, ExprStmtData, MacroInvocationData, NumberLiteralData, StringLiteralData, BooleanLiteralData, ArrayLiteralData, HiddenStdConvData, DeclKind, TypeKind, Type, Symbol, SymbolKind, MethodDeclData } from "../../ast/node";
import { readonlyDataConstBinding } from "../../checker/constFold";
import { hasGenericParams, isIntegerType, isNumeric, classParentOf, storesNothing, getProperty, peelToStructOrUnion, skipModifier } from "../../checker/types";
import {
	CGen, CProc, CSection,
	createProc, add, addLine, addNewline, sec, nameSetHas, nameSetAdd, readProcStmts, readProcLocals,
	emitProcBody, clearProcBuffers, typeCacheSet, typeCacheGet, typeCacheHas, aliveSetHasDecl, aliveSetHasModule, internString, addCGenError,
	setLocalSymName, factClaimGeneric, scopeMangledParam, emitProcLocalsLine,
} from "./context";
import { genExpr } from "./expressions";
import { emitCallRaiseCheck, genStmt, isComptimeOnlyVarDecl, readonlyDataBracedInit, resolveEmitArgs } from "./statements";
import { mangle, mangledTypeName, mangleFieldName, mangledFunctionName, mangledGlobalName, safeName, staticFieldCName, isModuleGlobalVar } from "./names";
import { getTypeDesc, isNrvoReturnType, ccgIntroducedPtr, shouldIndirectParam, shouldConstParam, typeInfoRef, ensureRefArrayCellTypeInfo, isHcrImageModule, isNilableValueType, procHeader, assertExternLayout, isOpenArrayParam, returnsBorrow, openArrayDataName, openArrayLenName, isTypeBoundOp, enumCTypeName, hcrTypeInfoRef, zeroInit, defineDeferredElements } from "./types";
import { genTestDeclNode } from "./test";
import { formatCNumberLit, cBoolLiteral, cStringLiteral, msStringPoolRef, cStringByteLen } from "./literals";
import { copiesInline, inlineDeclOf } from "./forward";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { bakesIntoStaticCell, functionDeclIsAlive } from "../../checker/reachability";
// NOTE: parser/context imports are in index.ms (not here) to avoid DRC union member count issues.

// ===== genDecl — main declaration dispatcher =====




export function genDecl(g: CGen, node: Readonly<Node>, exported: boolean): void {
	if (node == null) return;
	if (g.preparingDeclarations && node.kind != NodeKind.FunctionDecl
		&& node.kind != NodeKind.VariableDecl && node.kind != NodeKind.ExportDecl
		&& node.kind != NodeKind.DecoratedDecl) return;

	match (node.kind) {
		NodeKind.FunctionDecl => {
			if (!functionDeclIsAlive(g.aliveSet, g.modulePath, node)) return;
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
		NodeKind.TestDecl => {
			// Only emit test wrappers in test builds. Production builds strip
			// TestDecl entirely (genTestDeclNode itself no-ops when !isTestBuild;
			// the explicit check here skips descent for clarity + tiny codegen win).
			if (g.isTestBuild) { genTestDeclNode(g, node); }
		},
		NodeKind.AssertStmt => { genTopLevelStmt(g, node); },
		_ => { genTopLevelStmt(g, node); },
	};
}

// ===== Extern Declaration (non-function) =====
// Standard reference pattern: extern header provides the declaration.
// Only emit forward struct decl for opaque types without a providing header.
// Variables/consts: always provided by @include headers — no codegen emission.
// Functions: handled by FunctionDecl path (prototype only via SymbolFlag.ImportC).

function genExternDecl(g: CGen, node: Readonly<Node>): void {
	const d = node.data as ExternDeclData;

	if (d.externKind == ExternKind.Class || d.externKind == ExternKind.Type) {
		// Opaque type forward decl for classes/types without @include definition
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${d.externName} ${d.externName};`);
	}
	// extern interface: type defined in C header via @include — no forward decl needed.
	// Reference parity (sfImportc): importc types use the C name directly, no codegen emission.
	// Vars/consts/enums/macros: provided by @include headers, no emission needed.
}

// ===== Function Declaration =====

function genFunctionDecl(g: CGen, node: Readonly<Node>, exported: boolean, inlineCopy: boolean = false): void {
	const d = node.data as FunctionDeclData;
	const sym = node.resolvedSym;
	if (!inlineCopy && !g.preparingDeclarations && sym != null && copiesInline(g, sym)) return;

	// Tier 1: body-less overload signature — typecheck-only, skip codegen emission entirely.
	// The implementation (same name, no 'overload' flag) emits the actual C function.
	if (sym != null && (hasFlag(sym, SymbolFlag.OverloadSig) || hasFlag(sym, SymbolFlag.Borrow))) return;
	if (sym != null && hasFlag(sym, SymbolFlag.CompileTime)) return;

	// Module-qualified name (Standard reference implementation parity)
	const isExternFn = (sym != null && hasFlag(sym, SymbolFlag.ImportC)) || d.fnFlags == "extern" || d.fnFlags.indexOf("extern", 0) >= 0;
	const ovIdx = sym != null ? sym.overloadIdx : 0;
	let name = mangledFunctionName(sym, d.fnName, ovIdx);

	// Track whether we already emitted the proto or the body
	const alreadyDeclared = nameSetHas(g.declaredProcs, name);
	nameSetAdd(g.declaredProcs, name);

	// Determine C return type — MUST have nodeType (Decisive Checker mandate)
	const fnType = node.nodeType;
	if (fnType == null) return;
	if (hasGenericParams(fnType) || isGenericFn(d.fnFlags)) return;
	const isGenericInstance = sym != null && sym.instantiatedFrom != null;
	if (g.preparingDeclarations) {
		if (isGenericInstance && g.preparationFacts != null
				&& (!g.preparationFacts.genericOwners.has(name) || sym.modulePath == g.modulePath)) {
			factClaimGeneric(g.preparationFacts, name, g.modulePath);
		}
		return;
	}
	let cRetType = getTypeDesc(g, fnType.typeReturn);
	// Null return type means void (not void*) — closures typed as `: void` may have null typeReturn
	if (fnType.typeReturn == null) cRetType = "void";
	const nrvo = isNrvoReturnType(fnType.typeReturn, fnType);

	// DRC lifecycle hooks have fixed ABI — skip struct-aware promotion.
	const isDrcHookFn = sym != null && hasFlag(sym, SymbolFlag.GeneratedOp);
	const protoMutBits: int32 = sym != null ? sym.mutatedParams : 0;

	const instanceAlreadyEmitted = isGenericInstance && (g.emittedInstances.has(name)
		|| (g.emissionFacts.genericOwners.has(name) && g.emissionFacts.genericOwners.readonlyGet(name) != g.modulePath));
	if (isGenericInstance && !instanceAlreadyEmitted && !inlineCopy) g.emittedInstances.add(name);

	// main() is never static — called from dispatcher
	// Lifted functions (sym === null) are always static
	// DRC lifecycle hooks need external linkage for cross-module access (reference parity).
	// Generic instances: not static, not exported — one definition, other modules get forward decl.
	const isExported = sym != null && (exported || hasFlag(sym, SymbolFlag.Exported) || sym.exportName != "");
	const exportPrefix = isExported && g.isHcr ? "MS_HCR_EXPORT " : "";
	const hcrCoreCallable = sym != null && sym.modulePath != "" && g.emissionFacts.hcrCoreUnits.has(g.modulePath);
	const isTypeBound = sym != null && isTypeBoundOp(sym);
	const isPublicLinkage = isExported || isExternFn || isDrcHookFn || isGenericInstance || isTypeBound || hcrCoreCallable;
	const linkage = isPublicLinkage ? "" : (sym != null ? "MS_LIB_PRIVATE " : "static ");
	const outOfLine = sym != null && hasFlag(sym, SymbolFlag.NoInline) ? "__attribute__((noinline)) " : "";
	const prefix = inlineCopy ? "static inline " : exportPrefix + outOfLine + linkage;

	// Emit prototype to ProcHeaders — NRVO functions return void (skip if already forward-declared)
	const actualRetType = nrvo ? "void" : cRetType;
	const proto = prefix + procHeader(g, name, fnType, d.params, protoMutBits, isDrcHookFn);

	// Extern functions with 'from' clause bind to existing C functions — header provides declaration.
	// Extern functions without 'from' use mangled name and need our prototype.
	const hasNativeName = (sym != null && sym.nativeName != "") || (d.nativeName != null && d.nativeName != "");
	if (isExternFn && hasNativeName) return;

	if (!alreadyDeclared && !inlineCopy) {
		addLine(sec(g, CSection.ProcHeaders), proto + ";");
	}

	// Extern functions: prototype only, no body
	if (isExternFn) return;

	// Emit function body to Procs
	// Skip body for duplicate generic instances — forward decl already emitted above.
	if (instanceAlreadyEmitted && !inlineCopy) return;
	if (d.fnBody != null) {
		const p = createProc(name, fnType.typeReturn);
		p.suppressRaiseCheck = isDrcHookFn || (sym != null && hasFlag(sym, SymbolFlag.NeverRaises));
		if (nrvo) p.isNrvo = true;
		// Populate param names + pointer promotion (auto-deref via indirectParams)
		const mutBits: int32 = sym != null ? sym.mutatedParams : 0;
		for (let pi = 0; pi < d.params.length; pi += 1) {
			const paramSym = node.paramSyms != null && pi < node.paramSyms.length ? node.paramSyms[pi] : null;
			p.params.push(d.params[pi]);
			scopeMangledParam(p, safeName(d.params[pi]));
			if (paramSym != null) setLocalSymName(p, paramSym, safeName(d.params[pi]));
			const isMutated = (mutBits & (1 << (pi as int32))) != 0;
			const bodyPromote = pi < fnType.typeChildren.length && (isDrcHookFn ? ccgIntroducedPtr(g.target, fnType.typeChildren[pi]) : shouldIndirectParam(g.target, fnType.typeChildren[pi], isMutated, pi == 0 && returnsBorrow(fnType)));
			if (bodyPromote) {
				p.indirectParams.push(d.params[pi]);
				if (paramSym != null) p.indirectSyms.push(paramSym);
			}
			if (pi < fnType.typeChildren.length && isOpenArrayParam(fnType.typeChildren[pi])) {
				const spanName = safeName(d.params[pi]);
				const spanType = getTypeDesc(g, skipModifier(fnType.typeChildren[pi]));
				emitProcLocalsLine(p, `${spanType} ${spanName} = { ${openArrayDataName(spanName)}, ${openArrayLenName(spanName)} };`);
			}
		}
		genStmt(g, p, d.fnBody);
		const procs = sec(g, CSection.Procs);
		addLine(procs, proto + " {");
		emitProcBody(p, procs);
		// Reference parity (BeforeRet_): emit default return after DRC cleanup labels
		// to satisfy C compiler's control flow analysis for non-void functions.
		if (!nrvo && actualRetType != "void") {
			addLine(procs, `  return (${actualRetType})${zeroInit(fnType.typeReturn)};`);
		}
		addLine(procs, "}");
		addNewline(procs);
	}
}

export function emitInlineCopies(g: CGen): void {
	for (let i = 0; i < g.inlineCopies.length; i += 1) {
		const decl = inlineDeclOf(g.inlineCopies[i]);
		if (decl != null) genFunctionDecl(g, decl, false, true);
	}
}

// ===== Overload Index Matching =====
// ===== Enum Declaration =====

// The C name of a declared type comes from the same sym-aware helper the
// Type-driven path (genObjectType/genEnumType) uses, so both spellings agree.
function declTypeSym(node: Readonly<Node>): Symbol | null {
	const t = node.nodeType;
	if (t != null && t.sym != null) return t.sym;
	return node.resolvedSym;
}

// Pre-register bare↔qualified C-name mappings for every module-level type decl
// BEFORE any emission. ensureDrcProto and the ctor call sites consult these;
// lazy registration in the gen* emitters is walk-order dependent (a DRC hook
// proto can be requested before its type materializes — bug100 union hooks).
export function registerDeclCName(g: CGen, node: Readonly<Node>): void {
	let n = node;
	if (n.kind == NodeKind.ExportDecl) {
		n = (n.data as ExportDeclData).exportedDecl;
	}
	if (n != null && n.kind == NodeKind.DecoratedDecl) {
		n = (n.data as DecoratedDeclData).decoratedNode;
	}
	if (n == null) return;
	const k = n.kind;
	if (k != NodeKind.InterfaceDecl && k != NodeKind.ClassDecl && k != NodeKind.EnumDecl
		&& k != NodeKind.StructDecl && k != NodeKind.TypeAliasDecl) return;
	if (n.flags.has(NodeFlag.ExternC)) return;
	const sym = declTypeSym(n);
	if (sym == null) return;
	const cn = mangledTypeName(sym, sym.name);
	typeCacheSet(g.typeCache, "decl:" + cn, cn);
	typeCacheSet(g.typeCache, "bare:" + cn, sym.name);
}

function genEnumDecl(g: CGen, node: Readonly<Node>): void {
	const d = node.data as EnumDeclData;

	// Extern enum: defined in C header — skip emission entirely.
	if (node.flags.has(NodeFlag.ExternC)) return;

	const name = mangledTypeName(declTypeSym(node), d.enumName);

	// Skip if already declared (check both declaration set and type cache)
	const key = "enum:" + name;
	if (nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, key)) return;
	nameSetAdd(g.declaredThings, name);

	// Register in type cache to prevent genEnumType from re-emitting
	typeCacheSet(g.typeCache, key, name);

	// Emit as typedef + #define constants (use explicit values if available)
	const types = sec(g, CSection.Types);
	const enumSym = declTypeSym(node);
	addLine(types, `typedef ${enumCTypeName(enumSym != null ? enumSym.symbolType : node.nodeType)} ${name};`);
	for (let i = 0; i < d.enumMembers.length; i += 1) {
		const val = (d.enumValues != null && i < d.enumValues.length) ? d.enumValues[i] : i;
		addLine(types, `#define ${name}_${d.enumMembers[i]} (((${name})${val}))`);
	}
	addNewline(types);
}

// ===== Interface Declaration (struct) =====

function genInterfaceDecl(g: CGen, node: Readonly<Node>): void {
	const d = node.data as InterfaceDeclData;

	// Extern interface: type defined externally — skip struct emission.
	// Reference parity: isImportedType() skips forward decl + struct body.
	if (node.flags.has(NodeFlag.ExternC)) {
		const sym = declTypeSym(node);
		if (sym != null && sym.symbolType != null) assertExternLayout(g, sym.symbolType);
		return;
	}

	// Skip uninstantiated generic interfaces (prelude templates with K, V, T params)
	const declType = node.nodeType;
	if (declType != null && hasGenericParams(declType)) return;

	const name = mangledTypeName(declTypeSym(node), d.interfaceName);

	// Skip if already declared (check both declaration set and type cache)
	const ifaceKey = "object:" + name;
	if (nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, ifaceKey)) return;
	nameSetAdd(g.declaredThings, name);

	// Register in type cache to prevent genObjectType from re-emitting
	typeCacheSet(g.typeCache, ifaceKey, name);

	// Forward declaration
	addLine(sec(g, CSection.ForwardDecls), `typedef struct ${name} ${name};`);

	// Pre-resolve field types (ensures nested type definitions are emitted before struct body)
	// For interface (Ref<Struct>), unwrap to get inner struct's fields. For struct (plain Struct), use directly.
	// Read fields from the RESOLVED type (typeNames + typeChildren) — this includes
	// fields inherited via `extends` / `= A & B` after Phase 2 field merging in
	// resolveInterface. d.interfaceFields holds only own-declared fields.
	let ifaceType = node.nodeType;
	if (ifaceType != null && ifaceType.kind == TypeKind.Ref && ifaceType.typeReturn != null) {
		ifaceType = ifaceType.typeReturn;
	}
	const fieldNames = ifaceType != null && ifaceType.typeNames != null ? ifaceType.typeNames : d.interfaceFields;
	const fieldTypes: string[] = [];
	for (let i = 0; i < fieldNames.length; i += 1) {
		const ft = (ifaceType != null && i < ifaceType.typeChildren.length) ? getTypeDesc(g, ifaceType.typeChildren[i]) : "void*";
		fieldTypes.push(ft);
	}

	// Full struct definition (all referenced types already emitted above)
	const types = sec(g, CSection.Types);
	addLine(types, `struct ${name} {`);
	for (let i = 0; i < fieldNames.length; i += 1) {
		addLine(types, `  ${fieldTypes[i]} ${mangleFieldName(fieldNames[i])};`);
	}
	addLine(types, "};");
	addNewline(types);
}

// ===== Class Declaration =====

function genClassDecl(g: CGen, node: Readonly<Node>): void {
	const d = node.data as ClassDeclData;

	// Merged callable-namespace attachment (Number.MAX_SAFE_INTEGER): the
	// name is a Function — no struct type exists, so emit only the constant
	// globals. Reachable because checkClassDecl resolves the class name to
	// the same-named Function symbol.
	if (node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.Function) {
		genStaticFieldGlobals(g, d);
		return;
	}

	// Extern class: type defined externally — emit typedef forward decl only.
	if (node.flags.has(NodeFlag.ExternC)) {
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${d.className} ${d.className};`);
		return;
	}

	if (node.nodeType != null && hasGenericParams(node.nodeType)) {
		genStaticFieldGlobals(g, d);
		return;
	}

	const name = mangledTypeName(declTypeSym(node), d.className);

	// Check if struct type already declared (by genObjectType for generic instances)
	const classKey = "object:" + name;
	const typeAlreadyDeclared = nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, classKey);
	nameSetAdd(g.declaredThings, name);
	genStaticFieldGlobals(g, d);

	// Emit struct type definition (skip if already declared by genObjectType for generic instances)
	if (!typeAlreadyDeclared) {
		// Register in type cache to prevent genObjectType from re-emitting
		typeCacheSet(g.typeCache, classKey, name);

		// Forward declaration
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${name} ${name};`);

		// Pre-resolve ALL field types, then emit struct atomically.
		// Phase 4: read flat field list from RESOLVED Type (includes parent fields
		// after resolveClass merge in resolvePass.ms). Walk d.classBody only for
		// static field globals + initializers (AST-decl-only concerns).
		const fieldTypes: string[] = [];
		const fieldNames: string[] = [];
		let classStructType = node.nodeType;
		if (classStructType != null && classStructType.kind == TypeKind.Ref && classStructType.typeReturn != null) {
			classStructType = classStructType.typeReturn;
		}
		if (classStructType != null && classStructType.typeNames != null && classStructType.typeChildren != null) {
			for (let i = 0; i < classStructType.typeNames.length; i += 1) {
				fieldNames.push(mangleFieldName(classStructType.typeNames[i]));
				fieldTypes.push(getTypeDesc(g, classStructType.typeChildren[i]));
			}
		}
		let structDef = `struct ${name} {\n`;
		for (let i = 0; i < fieldTypes.length; i += 1) {
			structDef = structDef + `  ${fieldTypes[i]} ${fieldNames[i]};\n`;
		}
		structDef = structDef + "};\n";
		const types = sec(g, CSection.Types);
		add(types, structDef);
		addNewline(types);
	}
}

function initializerLiteralType(literal: Readonly<Node>, declType: Type | null): Type | null {
	return literal.nodeType != null && literal.nodeType.kind == TypeKind.Float32 ? literal.nodeType : declType;
}

// Static field globals + initializer emission for a class body. Shared by the
// normal class path and the merged callable-namespace attachment.
function genStaticFieldGlobals(g: CGen, d: Readonly<ClassDeclData>): void {
	for (const member of d.classBody) {
		const inner = member.kind == NodeKind.DecoratedDecl ? (member.data as DecoratedDeclData).decoratedNode : member;
		if (inner != null && (inner.kind == NodeKind.MethodDecl || inner.kind == NodeKind.ConstructorDecl)) {
			addCGenError(g, `internal: callable member in class '${d.className}' reached C codegen before methodToFunction`, inner.location.line, inner.location.column);
			return;
		}
		if (member.kind != NodeKind.PropertyDecl) { continue; }
		const pd = member.data as PropertyDeclData;
		if (!pd.propIsStatic) { continue; }
		const cType = member.nodeType != null ? getTypeDesc(g, member.nodeType) : "double";
		const fieldSym = member.resolvedSym;
		if (fieldSym == null || !hasFlag(fieldSym, SymbolFlag.Static)) {
			addCGenError(g, `internal: static field '${d.className}.${pd.propName}' has no declaration symbol`, member.location.line, member.location.column);
			return;
		}
		const globalName = staticFieldCName(fieldSym);
		addLine(sec(g, CSection.GlobalVars), `${cType} ${globalName};`);
		if (pd.propInitializer != null) {
			match (pd.propInitializer.kind) {
				NodeKind.NumberLiteral => {
					const nd = pd.propInitializer.data as NumberLiteralData;
					addLine(sec(g, CSection.DatInit), `${globalName} = ${formatCNumberLit(nd, initializerLiteralType(pd.propInitializer, member.nodeType))};`);
				},
				NodeKind.StringLiteral => {
					const sv = (pd.propInitializer.data as StringLiteralData).value;
					addLine(sec(g, CSection.DatInit), `${globalName} = msStringFromCStr(${cStringLiteral(sv)});`);
				},
				NodeKind.BooleanLiteral => {
					const bv = (pd.propInitializer.data as BooleanLiteralData).boolValue;
					addLine(sec(g, CSection.DatInit), `${globalName} = ${cBoolLiteral(bv)};`);
				},
				_ => {
					addCGenError(g, "internal: a computed static initializer for '" + d.className + "." + pd.propName + "' reached C codegen unlowered in " + g.modulePath, member.location.line, member.location.column);
				},
			};
		}
	}
}

// genExportDecl and genDecoratedDecl inlined into genDecl (exported flag threading)

// ===== Top-level Statement =====

// ===== Top-Level @emit (Reference genEmit + determineSection parity) =====
// Resolves emit args (with backtick-interpolated symbols), then routes each line
// to the appropriate CSection based on section markers.

function genTopLevelEmit(g: CGen, mi: Readonly<MacroInvocationData>): void {
	const code = resolveEmitArgs(g, mi, null as unknown as CProc);
	// Split on newlines and route each line through section detection (reference pattern)
	let start = 0;
	let pos = 0;
	while (pos < code.length) {
		if (code.charAt(pos) == "\n") {
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
	else if (code.startsWith("/*DATINITSECTION*/")) target = CSection.DatInit;
	addLine(sec(g, target), code);
}

function genTopLevelStmt(g: CGen, node: Readonly<Node>): void {
	// Global variable declarations go to GlobalVars section
	if (node.kind == NodeKind.VariableDecl) {
		if (isComptimeOnlyVarDecl(node)) return;
		if (!isInitProcLocal(node)) {
			genGlobalVar(g, node);
			return;
		}
		if (g.preparingDeclarations) return;
	}
	// Handle top-level directives
	if (node.kind == NodeKind.ExprStmt) {
		const esd = node.data as ExprStmtData;
		if (esd.expr.kind == NodeKind.MacroInvocation) {
			const mi = esd.expr.data as MacroInvocationData;
			// @emit: codegen handles directly (Reference genEmit parity — p.prc == nil path)
			if (mi.macroName == "emit" && mi.macroArgs.length > 0) {
				genTopLevelEmit(g, mi);
				return;
			}
			// @include/@compile/@link/@passC/@passL: already handled by checker directives
			if (mi.macroName == "include" || mi.macroName == "compile" || mi.macroName == "link" || mi.macroName == "passC" || mi.macroName == "passL") {
				return;
			}
		}
	}
	// Other statements go to ModuleInit — use shared initProc for consistent temp counter
	const atExit = node.flags.has(NodeFlag.GlobalDestroys);
	if (atExit && !aliveSetHasModule(g.aliveSet, g.modulePath)) return;
	const p = atExit ? g.deinitProc : g.initProc;
	const target = atExit ? CSection.ModuleDeinit : CSection.ModuleInit;
	genStmt(g, p, node);
	const locals = readProcLocals(p);
	const stmts = readProcStmts(p);
	clearProcBuffers(p);
	if (locals.length > 0) {
		add(sec(g, target), locals);
	}
	if (stmts.length > 0) {
		add(sec(g, target), stmts);
	}
}

function isInitProcLocal(node: Readonly<Node>): boolean {
	return node.resolvedSym != null && !hasFlag(node.resolvedSym, SymbolFlag.Global);
}

// ===== Global Variable Declaration =====

function genGlobalVar(g: CGen, node: Readonly<Node>): void {
	const d = node.data as VariableDeclData;
	const isModuleSlot = isModuleGlobalVar(node.resolvedSym);
	const varName = !isModuleSlot ? safeName(d.declName) : mangledGlobalName(node.resolvedSym, d.declName);
	// Identifier references recompute the mangled name on demand via mangledGlobalName
	// (see expressions.ms isModuleGlobalVar branch). We deliberately DO NOT write to
	// sym.nativeName here: that field is an extern/FFI marker — codegen uses
	// `sym.nativeName !== ""` to route CallExpr through the native direct-call path
	// (discoverCallExpr short-circuit), which would break closure calls on any
	// module-level `let fn: (..) => T` variable.


	if (g.preparingDeclarations) return;
	const cType = getTypeDesc(g, node.nodeType);
	// Slots that are not module globals keep a bare name that can repeat across modules —
	// static linkage is what makes them collision-free; nothing outside this module can
	// reference them.
	const staticPfx = isModuleSlot ? "" : "static ";
	// Literal initializers → fold to C global initializer. This makes the global
	// READY at program load time instead of waiting for Init000 dispatch order.
	// Critical for things like `const INITIAL_CAPACITY: int32 = 32;` — if left to
	// Init000 and another module's Init000 runs first and reads INITIAL_CAPACITY
	// (e.g. via HashSet constructor), it reads 0 and loops forever.
	if (d.initializer != null) {
		const init = d.initializer;
		if (init.kind == NodeKind.NumberLiteral) {
			const nd = init.data as NumberLiteralData;
			const litStr = formatCNumberLit(nd, initializerLiteralType(init, node.nodeType));
			// Integer types: cast to suppress -Wimplicit-int-float-conversion.
			const castedLit = (node.nodeType != null && isIntegerType(node.nodeType))
				? `(${cType})${litStr}`
				: litStr;
			addLine(sec(g, CSection.GlobalVars), `${staticPfx}${cType} ${varName} = ${castedLit};`);
			nameSetAdd(g.declaredGlobals, varName);
			return;
		}
		if (init.kind == NodeKind.BooleanLiteral) {
			const bd = init.data as BooleanLiteralData;
			addLine(sec(g, CSection.GlobalVars), `${staticPfx}${cType} ${varName} = ${cBoolLiteral(bd.boolValue)};`);
			nameSetAdd(g.declaredGlobals, varName);
			return;
		}
		if (init.kind == NodeKind.StringLiteral && node.nodeType != null && node.nodeType.kind == TypeKind.String) {
			const sd = init.data as StringLiteralData;
			const poolName = internString(g.stringPool, sd.value);
			addLine(sec(g, CSection.GlobalVars), `${staticPfx}${cType} ${varName} = ${msStringPoolRef(poolName, cStringByteLen(sd.value))};`);
			nameSetAdd(g.declaredGlobals, varName);
			return;
		}
		// Solana keeps only .text and .rodata; a deep-const sized array or struct
		// whose leaves are scalar literals is emitted as C `const` with a braced
		// initializer (Nim genConstDefinition), never as writable static + Init000.
		// readonlyDataConstBinding must match moduleBindingNeedsWritableStorage,
		// or the SBF link fails where FREESTANDING E02 stayed silent.
		if (g.checkerCtx != null && g.checkerCtx.targetOs == "solana"
				&& d.declKind == DeclKind.Const
				&& readonlyDataConstBinding(node)) {
			const braced = readonlyDataBracedInit(init, node.nodeType);
			if (braced != "") {
				addLine(sec(g, CSection.GlobalVars), `const ${cType} ${varName} = ${braced};`);
				nameSetAdd(g.declaredGlobals, varName);
				return;
			}
		}
		if (bakesIntoStaticCell(node)) {
			if (init.kind == NodeKind.ObjectLiteral) {
				genBakedConstCell(g, node, varName, staticPfx, cType);
			} else {
				genBakedConstArrayCell(g, node, varName, staticPfx, cType);
			}
			return;
		}
	}
	// Always emit uninitialized declaration to GlobalVars
	addLine(sec(g, CSection.GlobalVars), `${staticPfx}${cType} ${varName};`);
	// Track the mangled name (must match what cross-module extern emission
	// produces) so dedup works across decl + extern paths.
	nameSetAdd(g.declaredGlobals, varName);

	// NullLiteral initializer on a value-type global → C-compound-literal zero
	// init (`x = (T){0};`) instead of `x = MS_NIL;`. MS_NIL is `void*` and a
	// struct/union/array can't accept it. Mirrors the local var path in
	// statements.ms (genVarDecl, NullLiteral + isStructCType branch). Without
	// this, matchLower's `let x = null` placeholder for top-level `const x: T =
	// match(...){...}` (where T is a value type — Struct/Union/Array/Tuple)
	// emits invalid C.
	if (d.initializer != null
			&& d.initializer.kind == NodeKind.NullLiteral
			&& node.nodeType != null
			&& isNilableValueType(node.nodeType)) {
		addLine(sec(g, CSection.ModuleInit), `  ${varName} = (${cType})${zeroInit(node.nodeType)};`);
		return;
	}
	if (d.initializer != null
			&& d.initializer.kind == NodeKind.NullLiteral
			&& node.nodeType != null
			&& (isNumeric(node.nodeType) || node.nodeType.kind == TypeKind.Boolean)) {
		addLine(sec(g, CSection.ModuleInit), `  ${varName} = 0;`);
		return;
	}
	// Non-trivial initializers go to ModuleInit (not valid as C global initializers)
	if (d.initializer != null) {
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
		emitCallRaiseCheck(p, d.initializer);
		const check = readProcStmts(p);
		clearProcBuffers(p);
		if (check.length > 0) add(sec(g, CSection.ModuleInit), check);
	}
}

function refuseBake(g: CGen, node: Readonly<Node>, why: string): void {
	const d = node.data as VariableDeclData;
	addCGenError(g, `internal: module constant '${d.declName}' was chosen for a static cell, but ${why} in ${g.modulePath}`, node.location.line, node.location.column);
}

function genBakedConstCell(g: CGen, node: Readonly<Node>, varName: string, staticPfx: string, cType: string): void {
	if (cType.length < 2 || cType.slice(cType.length - 1, cType.length) != "*") return refuseBake(g, node, `its C type '${cType}' is not a pointer`);
	const d = node.data as VariableDeclData;
	if (g.aliveSet.computed && !aliveSetHasDecl(g.aliveSet, node.resolvedSym, d.declName)) return;
	const body = cType.slice(0, cType.length - 1);
	if (isHcrImageModule(g, g.modulePath) && g.emissionFacts.hcrTypeInfoOwners.has(body)) return refuseBake(g, node, `its TypeInfo '${body}' belongs to a reloadable image`);
	const od = d.initializer.data as ObjectLiteralData;
	const p = g.initProc;
	let braced = "";
	let closuresOk = true;
	const owner = peelToStructOrUnion(node.nodeType);
	let i = 0;
	for (const prop of od.properties) {
		if (owner != null && owner.kind == TypeKind.Struct && storesNothing(owner, getProperty(owner, od.keys[i]))) {
			i = i + 1;
			continue;
		}
		const sv = prop.kind == NodeKind.StringLiteral ? (prop.data as StringLiteralData).value : "";
		const snippet = prop.kind == NodeKind.StringLiteral
			? msStringPoolRef(internString(g.stringPool, sv), cStringByteLen(sv))
			: genExpr(g, p, prop);
		if (prop.kind == NodeKind.ObjectLiteral && !snippet.endsWith(".env = NULL }")) closuresOk = false;
		if (braced.length > 0) braced = braced + ", ";
		braced = braced + "." + mangleFieldName(od.keys[i]) + " = " + snippet;
		i = i + 1;
	}
	const bakeLocals = readProcLocals(p);
	const bakeStmts = readProcStmts(p);
	clearProcBuffers(p);
	if (!closuresOk) return refuseBake(g, node, "a closure field carries an environment");
	if (bakeLocals.length > 0 || bakeStmts.length > 0) return refuseBake(g, node, "its fields need initialization code");
	const typeInfo = typeInfoRef(g, node.nodeType);
	const viaRegistry = isHcrImageModule(g, g.modulePath);
	addLine(sec(g, CSection.GlobalVars), `static struct { msRefHeader h; ${body} b; } ${varName}_konst_ = { { 1 << 30, -1, ${viaRegistry ? "NULL" : typeInfo}, 0 }, { ${braced} } };`);
	if (viaRegistry) addLine(sec(g, CSection.DatInit), `  ${varName}_konst_.h.type = ${typeInfo};`);
	addLine(sec(g, CSection.GlobalVars), `${staticPfx}${cType} ${varName} = &${varName}_konst_.b;`);
	nameSetAdd(g.declaredGlobals, varName);
}

function genBakedConstArrayCell(g: CGen, node: Readonly<Node>, varName: string, staticPfx: string, cType: string): void {
	if (cType.length < 2 || cType.slice(cType.length - 1, cType.length) != "*") return refuseBake(g, node, `its C type '${cType}' is not a pointer`);
	const t0 = node.nodeType!;
	const arrT = t0.kind == TypeKind.Ref ? t0.typeReturn : t0;
	if (arrT == null || arrT.kind != TypeKind.Array) return refuseBake(g, node, "its type is not a reference array");
	const d = node.data as VariableDeclData;
	if (g.aliveSet.computed && !aliveSetHasDecl(g.aliveSet, node.resolvedSym, d.declName)) return;
	const arrCType = cType.slice(0, cType.length - 1);
	const typeInfo = ensureRefArrayCellTypeInfo(g, arrT);
	const viaRegistry = isHcrImageModule(g, g.modulePath);
	addLine(sec(g, CSection.GlobalVars), `static struct { msRefHeader h; ${arrCType} b; } ${varName}_konst_ = { { 1 << 30, -1, ${viaRegistry ? "NULL" : typeInfo}, 0 }, { 0, NULL } };`);
	if (viaRegistry) addLine(sec(g, CSection.DatInit), `  ${varName}_konst_.h.type = ${typeInfo};`);
	addLine(sec(g, CSection.GlobalVars), `${staticPfx}${cType} ${varName} = &${varName}_konst_.b;`);
	nameSetAdd(g.declaredGlobals, varName);
}

function readonlyDataBracedInit(g: CGen, init: Readonly<Node>, t: Type | null): string {
	match (init.kind) {
		NodeKind.NumberLiteral => {
			return formatCNumberLit(init.data as NumberLiteralData, init.nodeType);
		},
		NodeKind.BooleanLiteral => {
			return cBoolLiteral((init.data as BooleanLiteralData).boolValue);
		},
		NodeKind.HiddenStdConv => {
			return readonlyDataBracedInit(g, (init.data as HiddenStdConvData).convExpr, t);
		},
		NodeKind.ArrayLiteral => {
			const ad = init.data as ArrayLiteralData;
			const elemT = t != null && t.kind == TypeKind.SizedArray ? t.typeReturn : null;
			let parts = "";
			for (const e of ad.elements) {
				const part = readonlyDataBracedInit(g, e, elemT);
				if (part == "") return "";
				parts = parts.length == 0 ? part : parts + ", " + part;
			}
			const arrayBraced = `{ ${parts} }`;
			return t != null && t.kind == TypeKind.SizedArray ? `{ ${arrayBraced} }` : arrayBraced;
		},
		NodeKind.ObjectLiteral => {
			const od = init.data as ObjectLiteralData;
			let parts = "";
			for (let i = 0; i < od.properties.length; i += 1) {
				const part = readonlyDataBracedInit(g, od.properties[i], null);
				if (part == "") return "";
				const kv = `.${mangleFieldName(od.keys[i])} = ${part}`;
				parts = parts.length == 0 ? kv : parts + ", " + kv;
			}
			return `{ ${parts} }`;
		},
		_ => { return ""; },
	};
}

import { createCGen, assembleOutput, scopeMangledParam } from "./context";
import { CheckerContext, GcMode, isGenericFn } from "../../checker/context";
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
	defineDeferredElements(g);
	return assembleOutput(g);
}

test "simple function" {
	const result = declOutput("function foo(): void { return; }");
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
	assert result.length > 50;
}
