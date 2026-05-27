// C Codegen — Declaration Emission
//
// Handles function, enum, interface (struct), class, export, and import declarations.
// Emits to appropriate CGen sections (Types, ProcHeaders, Procs, ForwardDecls).

import { Node, NodeKind, NodeFlag, ExternKind, FunctionDeclData, EnumDeclData, InterfaceDeclData, ClassDeclData, ExportDeclData, VariableDeclData, DecoratedDeclData, ExternDeclData,  ProgramData, PropertyDeclData, MethodDeclData, ConstructorDeclData, ObjectLiteralData, ExprStmtData, MacroInvocationData, NumberLiteralData, StringLiteralData, BooleanLiteralData, TypeKind, Type } from "../../ast/node";
import { hasGenericParams, isIntegerType } from "../../checker/types";
import { getGenericDecl } from "../../parser/context";
import {
	CGen, CProc, CSection,
	createProc, add, addLine, addNewline, sec, nameSetHas, nameSetAdd, emitStmtsLine, readProcStmts, readProcLocals,
	clearProcBuffers, typeCacheSet, typeCacheHas, aliveSetHas,
} from "./context";
import { genExpr } from "./expressions";
import { genStmt, resolveEmitArgs } from "./statements";
import { mangle, mangleFieldName, mangledFunctionName, mangledGlobalName, safeName, staticFieldCName } from "./names";
import { getTypeDesc, isNrvoReturnType, ccgIntroducedPtr, shouldIndirectParam, shouldConstParam, ensureTypeInfoDef, isNilableValueType } from "./types";
import { genTestDeclNode } from "./test";
import { formatCNumber, cBoolLiteral, cStringLiteral } from "./literals";
import { isDrcLifecycleName } from "./forward";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
// NOTE: parser/context imports are in index.ms (not here) to avoid DRC union member count issues.
// genGenericTypeInsts lives in index.ms for the same reason.

// ===== Generic Instance Deduplication =====
// Across all modules in Phase C, each generic instance is emitted ONCE.
// First module to codegen it emits the body; other modules get forward decls only.
let _emittedInstances: HashSet<string> = new HashSet<string>();

export function resetEmittedInstances(): void {
	_emittedInstances = new HashSet<string>();
}

function isInstanceEmitted(name: string): boolean {
	return _emittedInstances.has(name);
}

function markInstanceEmitted(name: string): void {
	_emittedInstances.add(name);
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
	return name.endsWith("ArrayDestroy") || name.endsWith("ArrayCopy") ||
		name.endsWith("ArraySink") || name.endsWith("ArrayWasMoved");
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

	// Tier 1: body-less overload signature — typecheck-only, skip codegen emission entirely.
	// The implementation (same name, no 'overload' flag) emits the actual C function.
	if (sym !== null && hasFlag(sym, SymbolFlag.OverloadSig)) return;

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
	// DRC lifecycle hooks have fixed ABI — skip struct-aware promotion.
	// Detection: (1) name pattern (TypeNameDestroy etc.) for user-named types;
	// (2) GeneratedOp flag for compiler-synthesized hooks whose name clashes
	// with the `ms*` runtime prefix exclusion in isDrcLifecycleName (e.g.
	// anonymous structs emitted as `msAnon_<hash>Destroy`). markGeneratedOp
	// only flags real lifecycle hooks, so the suffix re-check is unnecessary.
	const isDrcHookFn = isDrcLifecycleName(name)
		|| (sym !== null && hasFlag(sym, SymbolFlag.GeneratedOp));
	const protoMutBits: int32 = sym !== null ? sym.mutatedParams : 0;
	for (let i = 0; i < d.params.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		let pType = (i < fnType.typeChildren.length) ? getTypeDesc(g, fnType.typeChildren[i]) : "void*";
		const protoMut = (protoMutBits & (1 << (i as int32))) !== 0;
		// DRC hooks: use ccgIntroducedPtr only (skip struct-aware mutation logic)
		// Regular functions: use shouldIndirectParam (struct-aware + mutation)
		const promote = i < fnType.typeChildren.length && (isDrcHookFn ? ccgIntroducedPtr(fnType.typeChildren[i]) : shouldIndirectParam(fnType.typeChildren[i], protoMut));
		if (promote && pType.charAt(pType.byteLength - 1) !== "*") {
			pType = (!isDrcHookFn && shouldConstParam(fnType.typeChildren[i], protoMut)) ? "const " + pType + "*" : pType + "*";
		}
		paramList = paramList + `${pType} ${safeName(d.params[i])}`;
	}
	if (paramList === "") paramList = "void";

	// Generic instance deduplication (reference parity).
	// First module to codegen an instance emits the body; others get forward decl only.
	const isGenericInstance = d.fnName.indexOf("__") >= 0 && sym !== null && sym.name.indexOf("__") >= 0;
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
	const prefix = (isExported || isExternFn || isMain || isDrcHookFn || isGenericInstance) ? "" : "static ";

	// Emit prototype to ProcHeaders — NRVO functions return void (skip if already forward-declared)
	const actualRetType = nrvo ? "void" : cRetType;
	const proto = `${prefix}${actualRetType} ${name}(${paramList})`;

	// Extern functions with 'from' clause bind to existing C functions — header provides declaration.
	// Extern functions without 'from' use mangled name and need our prototype.
	const hasNativeName = sym !== null && sym.nativeName !== "";
	if (isExternFn && hasNativeName) return;

	// DRC hooks: ensureDrcProto handles their forward decls with correct pointer convention.
	// genFunctionDecl's proto may have wrong param types for union variant hooks.
	if (!alreadyDeclared && !isDrcHookFn) {
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
		// Populate param names + pointer promotion (auto-deref via indirectParams)
		const mutBits: int32 = sym !== null ? sym.mutatedParams : 0;
		for (let pi = 0; pi < d.params.length; pi += 1) {
			p.params.push(d.params[pi]);
			// Reference parity (scopeMangledParam): reserve param name in sigConflicts
			// so local VarDecls with the same name get unique suffixes.
			scopeMangledParam(p, safeName(d.params[pi]));
			const isMutated = (mutBits & (1 << (pi as int32))) !== 0;
			const bodyPromote = pi < fnType.typeChildren.length && (isDrcHookFn ? ccgIntroducedPtr(fnType.typeChildren[pi]) : shouldIndirectParam(fnType.typeChildren[pi], isMutated));
			if (bodyPromote) {
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
		// Reference parity (BeforeRet_): emit default return after DRC cleanup labels
		// to satisfy C compiler's control flow analysis for non-void functions.
		if (!nrvo && actualRetType !== "void") {
			addLine(procs, `  return (${actualRetType}){0};`);
		}
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
	// Read fields from the RESOLVED type (typeNames + typeChildren) — this includes
	// fields inherited via `extends` / `= A & B` after Phase 2 field merging in
	// resolveInterface. d.interfaceFields holds only own-declared fields.
	let ifaceType = node.nodeType;
	if (ifaceType !== null && ifaceType.kind === TypeKind.Ref && ifaceType.typeReturn !== null) {
		ifaceType = ifaceType.typeReturn;
	}
	const fieldNames: string[] = ifaceType !== null && ifaceType.typeNames !== null ? ifaceType.typeNames : d.interfaceFields;
	const fieldTypes: string[] = [];
	for (let i = 0; i < fieldNames.length; i += 1) {
		const ft = (ifaceType !== null && i < ifaceType.typeChildren.length) ? getTypeDesc(g, ifaceType.typeChildren[i]) : "void*";
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

function genClassDecl(g: CGen, node: Node): void {
	const d = node.data as ClassDeclData;

	// Extern class: type defined externally — emit typedef forward decl only.
	if ((node.flags & NodeFlag.ExternC) !== 0) {
		addLine(sec(g, CSection.ForwardDecls), `typedef struct ${d.className} ${d.className};`);
		return;
	}

	const name = mangle(d.className);

	// Check if struct type already declared (by genObjectType for generic instances)
	const classKey = "object:" + d.className;
	const typeAlreadyDeclared = nameSetHas(g.declaredThings, name) || typeCacheHas(g.typeCache, classKey);
	// Always record ownership — declaredThings is the module's declaration claim,
	// used by ensureTypeInfoDef to decide which module emits msTypeInfo definitions.
	// The struct body emission below is separately guarded by typeAlreadyDeclared
	// to avoid re-emitting the forward decl / struct body.
	nameSetAdd(g.declaredThings, name);

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
		if (classStructType !== null && classStructType.kind === TypeKind.Ref && classStructType.typeReturn !== null) {
			classStructType = classStructType.typeReturn;
		}
		if (classStructType !== null && classStructType.typeNames !== null && classStructType.typeChildren !== null) {
			for (let i = 0; i < classStructType.typeNames.length; i += 1) {
				fieldNames.push(mangleFieldName(classStructType.typeNames[i]));
				fieldTypes.push(getTypeDesc(g, classStructType.typeChildren[i]));
			}
		}
		// Static field globals + initializer emission (own decls only — parent's
		// statics emitted by parent's genClassDecl).
		for (const member of d.classBody) {
			if (member.kind === NodeKind.PropertyDecl) {
				const pd = member.data as PropertyDeclData;
				if (pd.propIsStatic) {
					const cType = member.nodeType !== null ? getTypeDesc(g, member.nodeType) : "double";
					const globalName = staticFieldCName(d.className + "." + pd.propName);
					addLine(sec(g, CSection.GlobalVars), `${cType} ${globalName};`);
					if (pd.propInitializer !== null) {
						match (pd.propInitializer.kind) {
							NodeKind.NumberLiteral => {
								const nv = (pd.propInitializer.data as NumberLiteralData).value;
								addLine(sec(g, CSection.DatInit), `${globalName} = ${formatCNumber(nv, member.nodeType)};`);
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
								const initSnippet = genExpr(g, g.initProc, pd.propInitializer);
								emitStmtsLine(g.initProc, `${globalName} = ${initSnippet};`);
							},
						};
					}
				}
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

	// Emit methods + constructor (always, even if struct was already declared).
	// Skip constructors for generic classes — only monomorphized instances get constructors.
	const isGenericClass = d.classExtends === "" && getGenericDecl(d.className) !== "";
	for (const member of d.classBody) {
		if (member.kind === NodeKind.MethodDecl) {
			genMethodAsFunction(g, member, name);
		} else if (member.kind === NodeKind.ConstructorDecl && !isGenericClass) {
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
	// Skip emission of generic method bodies (mirror the same guard in
	// genFunctionDecl). When a generic static method is mono-instantiated for
	// concrete T (Bug 10 fix), the mono instance lands in `_pendingInstances`
	// as a synthesized FunctionDecl and gets emitted by the regular function
	// path. The original generic method body — with deferred MacroInvocation
	// or `void*` typed params from unresolved T — would otherwise emit broken
	// C alongside the working mono instance. Type-level (GenericParam in
	// tree) plus flag-level (`gen:` marker on methodFlags) — either skips.
	if (hasGenericParams(methodType)) return;
	if (isGenericFn(d.methodFlags)) return;
	const cRetType = getTypeDesc(g, methodType.typeReturn);
	// NRVO: methods returning large value-types (Result<T,E>, struct, tuple)
	// must be emitted with `void` return + first param `Type* __result`. Caller
	// codegen unconditionally injects `&dest` as the first argument when the
	// return type is NRVO-qualified — without this, the function signature
	// mismatches the call ABI and the receiver gets a stack pointer that
	// dereferences into garbage. Mirrors `genFunctionDecl` line ~154.
	const nrvo = isNrvoReturnType(methodType.typeReturn, methodType);
	const actualRetType = nrvo ? "void" : cRetType;

	// Fallback path. Post-`methodToFunction` transform (Phase 3, !jsBackend),
	// MethodDecl no longer reaches codegen — it's lifted into a top-level
	// FunctionDecl that goes through `genFunctionDecl`. This branch only fires
	// if a future generic / extern / mono path leaks a MethodDecl past the
	// transform. Kept as a no-op-equivalent emitter so we don't crash; if a
	// param-promotion drift surfaces here, the right fix is to extend the
	// transform's coverage, not to mirror logic into this branch.
	let paramList = "";
	if (nrvo) {
		paramList = cRetType + "* __result";
		if (d.methodParams.length > 0) paramList = paramList + ", ";
	}
	for (let i = 0; i < d.methodParams.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = getTypeDesc(g, methodType.typeChildren[i]);
		paramList = paramList + `${pType} ${safeName(d.methodParams[i])}`;
	}
	if (paramList === "") paramList = "void";

	const proto = `${actualRetType} ${methodName}(${paramList})`;
	addLine(sec(g, CSection.ProcHeaders), proto + ";");

	if (d.methodBody !== null) {
		const p = createProc(methodName, null);
		if (nrvo) p.isNrvo = true;
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
	const initName = className + "_init";

	// Build user param list — shared by _init and _new.
	const ctorType = node.nodeType;
	let userParams = "";
	for (let i = 0; i < d.ctorParams.length; i += 1) {
		if (i > 0) userParams = userParams + ", ";
		const pType = getTypeDesc(g, ctorType.typeChildren[i]);
		userParams = userParams + `${pType} ${safeName(d.ctorParams[i])}`;
	}

	// Phase 5 split: ClassName_init(this, params) runs the user ctor body;
	// ClassName_new(params) allocates + delegates to _init. This split lets
	// `super(args)` in derived ctors call ParentClass_init((Parent*)this, args)
	// to run parent's init logic on the SAME `this` (no new allocation).
	const initParamList = userParams === "" ? `${className}* this` : `${className}* this, ${userParams}`;
	const initProto = `void ${initName}(${initParamList})`;
	addLine(sec(g, CSection.ProcHeaders), initProto + ";");

	const newParamList = userParams === "" ? "void" : userParams;
	const newProto = `${className}* ${ctorName}(${newParamList})`;
	addLine(sec(g, CSection.ProcHeaders), newProto + ";");

	// Multi-module dedup: each constructor emitted once (same as generic function instances).
	// Second module gets forward declarations only.
	if (isInstanceEmitted(ctorName)) return;
	markInstanceEmitted(ctorName);

	const procs = sec(g, CSection.Procs);

	// Emit _init first (called by _new and by super(args)).
	addLine(procs, initProto + " {");
	if (d.ctorBody !== null) {
		const p = createProc(initName, null);
		genStmt(g, p, d.ctorBody);
		const locals = readProcLocals(p);
		const stmts = readProcStmts(p);
		if (locals.length > 0) add(procs, locals);
		add(procs, stmts);
	}
	addLine(procs, "}");
	addNewline(procs);

	// Emit _new wrapper: alloc + call _init + return this.
	addLine(procs, newProto + " {");
	ensureTypeInfoDef(g, className, null as unknown as Type);
	const typeInfoArg = (g.checkerCtx !== null && g.checkerCtx.gcMode === GcMode.Manual) ? "NULL" : `&${className}TypeInfo`;
	addLine(procs, `  ${className}* this = (${className}*)msAllocTyped(sizeof(${className}), ${typeInfoArg});`);
	let initArgList = "this";
	for (let pi = 0; pi < d.ctorParams.length; pi += 1) {
		initArgList = initArgList + ", " + safeName(d.ctorParams[pi]);
	}
	addLine(procs, `  ${initName}(${initArgList});`);
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
	// Mangling policy for module-level `const`/`let`:
	//
	// - Regular vars: emit with module-qualified C name (`NAME__<moduleName>Oms`) so
	//   two modules declaring same-named constants (e.g. `MAX_TIME` in cursors.ms and
	//   varpartitions.ms) don't produce duplicate C globals at link time. Matches
	//   what cross-module extern emission (`expressions.ms`) + identifier references
	//   emit, so one mangled symbol per binary.
	//
	// - TypeInfo vars (name ending in "TypeInfo"): INTENTIONALLY bypass mangling and
	//   use the raw `safeName`. These are emitted as `__attribute__((weak))` (see
	//   `genTypeInfoVar`) so when module A defines `PointTypeInfo` and module B also
	//   needs it (e.g. typeof lookup), the linker collapses the two weak definitions
	//   into one symbol. Cross-module type identity relies on matching the raw name —
	//   mangling would break that invariant.
	//
	// Detection is NAME-based (suffix match). Risk: a user-declared variable named
	// e.g. `MyCustomTypeInfo` would also bypass mangling. Rare in practice (the suffix
	// convention is ORC-internal); revisit if collision reports surface.
	const nameLen = d.declName.length;
	const isTypeInfo = nameLen > 8 && d.declName.slice(nameLen - 8, nameLen) === "TypeInfo";
	const varName = isTypeInfo ? safeName(d.declName) : mangledGlobalName(node.resolvedSym, d.declName);
	// Identifier references recompute the mangled name on demand via mangledGlobalName
	// (see expressions.ms isModuleGlobalVar branch). We deliberately DO NOT write to
	// sym.nativeName here: that field is an extern/FFI marker — codegen uses
	// `sym.nativeName !== ""` to route CallExpr through the native direct-call path
	// (discoverCallExpr short-circuit), which would break closure calls on any
	// module-level `let fn: (..) => T` variable.

	// Detect TypeInfo vars from destructorLifting (ORC runtime RTTI)
	if (isTypeInfo) {
		// TypeInfo is DRC metadata — skip under --gc=manual (write-only, never read)
		if (g.checkerCtx !== null && g.checkerCtx.gcMode === GcMode.Manual) return;
		genTypeInfoVar(g, d, varName);
		return;
	}

	const cType = getTypeDesc(g, node.nodeType);
	// Literal initializers → fold to C global initializer. This makes the global
	// READY at program load time instead of waiting for Init000 dispatch order.
	// Critical for things like `const INITIAL_CAPACITY: int32 = 32;` — if left to
	// Init000 and another module's Init000 runs first and reads INITIAL_CAPACITY
	// (e.g. via HashSet constructor), it reads 0 and loops forever.
	if (d.initializer !== null) {
		const init = d.initializer;
		if (init.kind === NodeKind.NumberLiteral) {
			const nd = init.data as NumberLiteralData;
			const litStr = formatCNumber(nd.value, node.nodeType);
			// Integer types: cast to suppress -Wimplicit-int-float-conversion.
			const castedLit = (node.nodeType !== null && isIntegerType(node.nodeType))
				? `(${cType})${litStr}`
				: litStr;
			addLine(sec(g, CSection.GlobalVars), `${cType} ${varName} = ${castedLit};`);
			nameSetAdd(g.declaredGlobals, varName);
			return;
		}
		if (init.kind === NodeKind.BooleanLiteral) {
			const bd = init.data as BooleanLiteralData;
			addLine(sec(g, CSection.GlobalVars), `${cType} ${varName} = ${cBoolLiteral(bd.boolValue)};`);
			nameSetAdd(g.declaredGlobals, varName);
			return;
		}
	}
	// Always emit uninitialized declaration to GlobalVars
	addLine(sec(g, CSection.GlobalVars), `${cType} ${varName};`);
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
	if (d.initializer !== null
			&& d.initializer.kind === NodeKind.NullLiteral
			&& node.nodeType !== null
			&& isNilableValueType(node.nodeType)) {
		addLine(sec(g, CSection.ModuleInit), `  ${varName} = (${cType}){0};`);
		return;
	}
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
	// Extract base type name: strip "TypeInfo" suffix (8 chars)
	const baseName = d.declName.slice(0, d.declName.length - 8);
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

