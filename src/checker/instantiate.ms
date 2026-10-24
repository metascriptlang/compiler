// On-Demand Generic Instantiation — generateInstance + replaceTypeVars pattern
//
// When a generic extension method is matched during type checking,
// immediately clone the function body, substitute types, and register
// the specialized version. No separate monomorphize pass needed.

import { methodOwnerClass } from "./visibility";
import { isAsyncFunctionNode } from "./freestanding";
import { Node, NodeKind, NodeData, NodeFlag, SourceLocation, makeLoc, createNodeAt, FunctionDeclData, ReturnStmtData, MethodDeclData as MethodDeclDataLocal, ClassDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, PropertyDeclData, IdentifierData, HiddenDerefData, HiddenStdConvData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { isMaybeType, createGenericParam, inferredType, isUnresolvedType, createFunction, createRef, createStruct, isStructType, typeDisplayName, voidType, createEnum, createEnumLiteral, int32Type, createUnifyBindings, unifyType, hasGenericParams, createGenericInstance, isAwaitable, unwrapRef, genericParamsOf, instantiateGenericBody, symGenericParams, isReadonlyView, classParentOf, runtimeClassSym, genericParamNamesOf, substituteParams, substituteBound, declaredTypeParams, TypeVisitSet, typeVisitAdd, isDeclaredStruct, UnifyBindings, bindParam, bindAt, boundSlot } from "./types";
import { ensureShaped, registerTypeInstanceHooks, refuseHookInferredReturn } from "./resolvePass";
import { lookupSymbol, makeSymbol, initFnName, addSymbolToScope, globalScope, SymbolFlag, hasFlag, setFlag, openScope, Scope, ScopeKind } from "./symbol";
import { mintCtorRoutine, resetCtorRoutines, ctorRoutineOf, ctorFormalTypes } from "./ctorRoutine";
import { splitTopLevel } from "../utils/string";
import { monoRoutineBaseName } from "../monomorphize/registry";
import { callCheckExpr } from "./checkerCallbacks";
import { fitNode } from "./fit";
import { CheckerContext, stripGenFlag, getExtReceiverType, isExtensionFlag, registerExtension, truncateExtensions, addError, findAllExtensionsByName, hasExtensionByName, isEngineCheckMode, nominalTypeSym, declaresLifecycleHook, newSym, stampItem, LIFECYCLE_HOOK_NAMES, isLifecycleHookName } from "./context";
import { createContext, resetDefaultsCheckedAtDeclaration } from "./context";
import { monoCloneNode } from "../monomorphize/clone";
import { mangleMonoName, monoInstanceNameOf } from "../monomorphize/registry";
import { callCheckFunctionBody, callCheckLocalInstance, registerInstantiateGeneric } from "./checkerCallbacks";
import { checkRoutineBorrows } from "./varPartitions";
import { beginGensymUnit, rewindTemplateGensym } from "./template";
import { getIdentId } from "./idents";
import { fitJoinedBranch, settleYields, isSyncGeneratorFlags } from "./fit";
import { bindFunctionFlow } from "../binder/index";
import { CheckedInstantiation } from "./context";
import { TypeFlag } from "../ast/node";
import { sameType } from "./compat";

// ===== Module-Path → CheckerContext Registry =====
// When a generic body (function or class constructor) is cloned and re-checked
// during monomorphization, private module-level symbols in the defining module
// (e.g. `const INITIAL_CAPACITY` in std/core/struct.ms) must resolve. They live
// in the defining module's scope, not the caller's. This registry maps modulePath
// → ctx so the body re-check can target the correct scope.
//
// Reference parity: Nim's `graph.ifaces[itemId.module]` serves the same role.
//
// Populated by checkProgramCore (checkPass.ms) at the end of each module's check.
// Looked up by instantiateGenericFunction / instantiateClassConstructor.
let _moduleCtxMap: HashMap<string, CheckerContext> = new HashMap<string, CheckerContext>();
let _localGenerics: HashMap<Symbol, Scope> = new HashMap<Symbol, Scope>();
let _localInstances: HashMap<Symbol, Node[]> = new HashMap<Symbol, Node[]>();

export function registerModuleCtx(modulePath: string, ctx: CheckerContext): void {
	if (modulePath == "") return;
	_moduleCtxMap.set(modulePath, ctx);
}

export function lookupModuleCtx(modulePath: string): CheckerContext | null {
	if (modulePath == "") return null;
	if (!_moduleCtxMap.has(modulePath)) return null;
	return _moduleCtxMap.get(modulePath);
}

// Stored here (not as Module field) because src/module/graph.ms is forbidden
// from importing ast/ types. Same pattern as _moduleCtxMap above.
let _moduleProgramMap: HashMap<string, Node> = new HashMap<string, Node>();

export function registerModuleProgram(modulePath: string, program: Node): void {
	if (modulePath == "") return;
	_moduleProgramMap.set(modulePath, program);
}

export function lookupModuleProgram(modulePath: string): Node | null {
	if (modulePath == "") return null;
	if (!_moduleProgramMap.has(modulePath)) return null;
	return _moduleProgramMap.get(modulePath);
}

export interface ModuleCtxRegistry {
	ctxs: HashMap<string, CheckerContext>;
	programs: HashMap<string, Node>;
}

export function createModuleCtxRegistry(): ModuleCtxRegistry {
	return { ctxs: new HashMap<string, CheckerContext>(), programs: new HashMap<string, Node>() };
}

export function swapModuleCtxRegistry(next: ModuleCtxRegistry): ModuleCtxRegistry {
	const prev: ModuleCtxRegistry = { ctxs: _moduleCtxMap, programs: _moduleProgramMap };
	_moduleCtxMap = next.ctxs;
	_moduleProgramMap = next.programs;
	return prev;
}

// Pick the right ctx for re-checking a body defined in `definingModulePath`:
//   1. Self-module (caller is also the defining module) — use ctx directly. The
//      module is currently being checked, so its scope is live but not yet in
//      the registry (registration happens at end of checkProgramCore).
//   2. Registry — another user module that has already finished checking.
//   3. preludeCtx — stdlib/prelude modules share a single ctx, not registered
//      via checkProgramCore. This fallback covers them.
//   4. Caller's ctx — last resort when all lookups miss.
// Reference parity: Nim's `graph.ifaces[module]` via the `symMap` for generic
// instantiation body re-check.
let _engineBodyCtxFn: (definingModulePath: string, owner: Symbol | null) => CheckerContext | null = (definingModulePath: string, owner: Symbol | null): CheckerContext | null => null;

export function registerEngineBodyCtxFn(fn: (definingModulePath: string, owner: Symbol | null) => CheckerContext | null): void {
	_engineBodyCtxFn = fn;
}

// The checked scope a routine declared in another module is compiled against: the module's own
// context, or a view of the prelude module that declares it, its private names over the prelude's
// exports. `null` when neither holds it; the caller's scope is never a substitute.
export function declaringModuleCtx(ctx: CheckerContext, sym: Symbol): CheckerContext | null {
	if (sym.modulePath == "" || sym.modulePath == ctx.modulePath) return ctx;
	const defining = lookupModuleCtx(sym.modulePath);
	if (defining != null) return defining;
	const own = preludeModuleCtx(ctx, sym.modulePath);
	if (own != null) return own;
	const prelude = ctx.preludeCtx != null ? ctx.preludeCtx : ctx;
	let scope: Scope | null = prelude.table.current;
	while (scope != null) {
		for (const held of scope.symbols.values()) {
			if (held.modulePath == sym.modulePath) return prelude;
		}
		scope = scope.parent;
	}
	return null;
}

export function preludeModuleCtx(ctx: CheckerContext, modulePath: string): CheckerContext | null {
	const prelude = ctx.preludeCtx != null ? ctx.preludeCtx : ctx;
	const members = prelude.preludeModuleScopes.get(modulePath);
	if (members == null) return null;
	const view = createContext();
	view.table.identCache = prelude.table.identCache;
	view.table.current = globalScope(prelude.table);
	openScope(view.table, ScopeKind.Module);
	for (const s of members) addSymbolToScope(view.table.current, s);
	view.modulePath = modulePath;
	view.preludeCtx = prelude;
	view.extensionRegistry = prelude.extensionRegistry;
	view.exportRegistry = prelude.exportRegistry;
	view.compilerFuncs = prelude.compilerFuncs;
	return view;
}

export function pickBodyCtx(definingModulePath: string, ctx: CheckerContext, owner: Symbol | null = null): CheckerContext {
	if (definingModulePath == "" || definingModulePath == ctx.modulePath) return ctx;
	if (isEngineCheckMode()) {
		const engineCtx = _engineBodyCtxFn(definingModulePath, owner);
		if (engineCtx != null) return engineCtx;
	}
	const defining = lookupModuleCtx(definingModulePath);
	if (defining != null) return defining;
	if (ctx.preludeCtx != null) return preludeBodyCtx(ctx.preludeCtx, definingModulePath);
	return ctx;
}

const _preludeBodyCtxs = new HashMap<CheckerContext, HashMap<string, CheckerContext>>();

export function preludeBodyCtx(prelude: CheckerContext, modulePath: string): CheckerContext {
	let views = _preludeBodyCtxs.get(prelude);
	if (views == null) {
		views = new HashMap<string, CheckerContext>();
		_preludeBodyCtxs.set(prelude, views);
	}
	const known = views.get(modulePath);
	if (known != null) return known;
	const own = preludeModuleCtx(prelude, modulePath) ?? prelude;
	views.set(modulePath, own);
	return own;
}

export function resetInstantiationState(): void {
	_localGenerics = new HashMap<Symbol, Scope>();
	_localInstances = new HashMap<Symbol, Node[]>();
	_placedInstances = new HashMap<Symbol, Symbol>();
	_moduleCtxMap = new HashMap<string, CheckerContext>();
	_moduleProgramMap = new HashMap<string, Node>();
	resetCtorRoutines();
	resetDefaultsCheckedAtDeclaration();
	_instanceHooks = new HashMap<Symbol, InstanceHook[]>();
	_hookScannedInstances = new HashMap<Symbol, Type[][]>();
	_checkedInstances = new HashMap<Symbol, CheckedInstantiation>();
}

interface InstanceHook {
	concreteTypes: Type[];
	methodName: string;
	sym: Symbol;
}

let _instanceHooks: HashMap<Symbol, InstanceHook[]> = new HashMap<Symbol, InstanceHook[]>();
let _hookScannedInstances: HashMap<Symbol, Type[][]> = new HashMap<Symbol, Type[][]>();
let _checkedInstances: HashMap<Symbol, CheckedInstantiation> = new HashMap<Symbol, CheckedInstantiation>();

export function checkedInstanceOf(sym: Symbol): CheckedInstantiation {
	const inst = _checkedInstances.get(sym);
	if (inst == null) throw new Error(`internal: instance '${sym.name}' has no retained checked arguments`);
	return inst;
}

export function sameCheckedInstance(a: Symbol, b: Symbol): boolean {
	if (a == b) return true;
	return a.instantiatedFrom != null && a.instantiatedFrom == b.instantiatedFrom
		&& sameInstanceArgs(checkedInstanceOf(a).concreteTypes, checkedInstanceOf(b).concreteTypes);
}

function instanceHook(owner: Symbol, types: Type[], methodName: string): Symbol | null {
	const hooks = _instanceHooks.get(owner);
	if (hooks == null) return null;
	for (const hook of hooks) {
		if (hook.methodName == methodName && sameInstanceArgs(hook.concreteTypes, types)) return hook.sym;
	}
	return null;
}

function recordInstanceHook(owner: Symbol, types: Type[], methodName: string, sym: Symbol): void {
	let hooks = _instanceHooks.get(owner);
	if (hooks == null) {
		hooks = [];
		_instanceHooks.set(owner, hooks);
	}
	for (const hook of hooks) {
		if (hook.methodName == methodName && sameInstanceArgs(hook.concreteTypes, types)) {
			hook.sym = sym;
			return;
		}
	}
	hooks.push({ concreteTypes: types, methodName, sym });
}

export function lookupInstanceHook(type: Type, methodName: string): Symbol | null {
	let t = type;
	while ((t.kind == TypeKind.Ref || t.kind == TypeKind.Var || t.kind == TypeKind.Ptr) && t.typeReturn != null) t = t.typeReturn;
	if (t.kind == TypeKind.GenericInstance) {
		const owner = nominalTypeSym(t);
		return owner != null ? instanceHook(owner, t.typeChildren, methodName) : null;
	}
	if (t.sym != null && t.sym.instantiatedFrom != null) {
		return instanceHook(t.sym.instantiatedFrom, checkedInstanceOf(t.sym).concreteTypes, methodName);
	}
	return null;
}

export function declaresUserHook(t: Type, ctx: CheckerContext): boolean {
	for (const hookName of LIFECYCLE_HOOK_NAMES) {
		if (lookupInstanceHook(t, hookName) != null) return true;
	}
	const owner = nominalTypeSym(t);
	return owner != null && declaresLifecycleHook(pickBodyCtx(owner.modulePath, ctx, owner), owner);
}

function instantiateInstanceHooks(owner: Symbol, classData: ClassDeclData, instanceName: string, params: Type[], types: Type[], ctx: CheckerContext, loc: SourceLocation): void {
	for (const raw of classData.classBody) {
		const member = raw.kind == NodeKind.DecoratedDecl ? (raw.data as DecoratedDeclData).decoratedNode : raw;
		if (member == null || member.kind != NodeKind.MethodDecl) continue;
		const md = member.data as MethodDeclDataLocal;
		if (md.methodIsStatic || !isLifecycleHookName(md.methodName)) continue;
		const hookSym = member.resolvedSym;
		if (hookSym == null) {
			addError(ctx, "internal: hook '" + md.methodName + "' of generic class instance '" + instanceName + "' has no symbol", loc.line, loc.column);
			continue;
		}
		ensureShaped(hookSym, ctx);
		const inst = instantiateGenericFunction(hookSym, params, types, ctx, loc);
		if (inst != null) recordInstanceHook(owner, types, md.methodName, inst);
	}
}

function instantiateExtensionHooks(genericSym: Symbol, instType: Type, ctx: CheckerContext, loc: SourceLocation): boolean {
	const registry = pickBodyCtx(genericSym.modulePath, ctx, genericSym).extensionRegistry;
	if (registry == null) return true;
	let settled = true;
	for (const hookName of LIFECYCLE_HOOK_NAMES) {
		if (instanceHook(genericSym, instType.typeChildren, hookName) != null) continue;
		if (!hasExtensionByName(registry, hookName)) continue;
		for (const m of findAllExtensionsByName(registry, hookName)) {
			const hookSym = m.sym;
			if (m.isStatic || hookSym == null || hookSym.modulePath != genericSym.modulePath) continue;
			if (hookSym.declNode == null || hookSym.declNode.kind != NodeKind.FunctionDecl) continue;
			if (hookSym.state == SymbolState.Shaping) {
				settled = false;
				continue;
			}
			ensureShaped(hookSym, ctx);
			const fnType = hookSym.symbolType;
			if (fnType == null || fnType.typeChildren.length == 0) {
				settled = false;
				continue;
			}
			let formal = fnType.typeChildren[0];
			while ((formal.kind == TypeKind.Var || formal.kind == TypeKind.Ref || formal.kind == TypeKind.Ptr) && formal.typeReturn != null) formal = formal.typeReturn;
			if (formal.kind != TypeKind.GenericInstance || nominalTypeSym(formal) != genericSym) continue;
			if (!hasGenericParams(formal)) {
				if (!sameInstanceType(formal, instType)) continue;
				recordInstanceHook(genericSym, instType.typeChildren, hookName, hookSym);
				break;
			}
			const bindings = createUnifyBindings();
			unifyType(formal, instType, bindings);
			if (bindings.names.length == 0) continue;
			const inst = instantiateGenericFunction(hookSym, bindings.params, bindings.types, ctx, loc);
			if (inst != null) recordInstanceHook(genericSym, instType.typeChildren, hookName, inst);
			break;
		}
	}
	return settled;
}

function markInstanceHookType(t: Type, owner: Symbol): void {
	const hooks = _instanceHooks.get(owner);
	if (hooks == null) return;
	for (const hook of hooks) {
		if (!sameInstanceArgs(hook.concreteTypes, t.typeChildren)) continue;
		t.typeFlags = t.typeFlags.incl(TypeFlag.HasAsgn);
		if (t.typeReturn != null) t.typeReturn.typeFlags = t.typeReturn.typeFlags.incl(TypeFlag.HasAsgn);
		return;
	}
}

function instantiateHooksInType(t: Type | null, ctx: CheckerContext, loc: SourceLocation, depth: int32): void {
	if (t == null || depth > 8) return;
	const k = t.kind;
	if (k == TypeKind.Union || k == TypeKind.Tuple) {
		for (const c of t.typeChildren) instantiateHooksInType(c, ctx, loc, depth + 1);
		return;
	}
	if (k == TypeKind.Ref || k == TypeKind.Ptr || k == TypeKind.Var || k == TypeKind.Sink || k == TypeKind.Array || k == TypeKind.SizedArray) {
		instantiateHooksInType(t.typeReturn, ctx, loc, depth + 1);
		return;
	}
	if (k != TypeKind.GenericInstance || isAwaitable(t) || isUnresolvedType(t) || hasGenericParams(t)) return;
	const base = t.typeExtra != null ? unwrapRef(t.typeExtra) : null;
	const owner = base != null ? base.sym : null;
	if (owner == null) return;
	let scanned = _hookScannedInstances.get(owner);
	if (scanned == null) {
		scanned = [];
		_hookScannedInstances.set(owner, scanned);
	}
	for (const args of scanned) {
		if (sameInstanceArgs(args, t.typeChildren)) {
			markInstanceHookType(t, owner);
			return;
		}
	}
	const at = scanned.length;
	scanned.push(t.typeChildren);
	for (const arg of t.typeChildren) instantiateHooksInType(arg, ctx, loc, depth + 1);
	const settled = instantiateExtensionHooks(owner, t, ctx, loc);
	if (t.typeReturn == null) {
		const params = genericParamsOf(t);
		if (params != "") instantiateGenericBody(t, params);
	}
	const body = t.typeReturn != null ? unwrapRef(t.typeReturn) : null;
	if (body != null && body.kind == TypeKind.Struct) {
		for (const field of body.typeChildren) instantiateHooksInType(field, ctx, loc, depth + 1);
	}
	markInstanceHookType(t, owner);
	if (!settled) scanned.splice(at, 1);
}

export function instanceGenericOf(node: Node): Symbol | null {
	const sym = node.resolvedSym;
	if (sym == null) return null;
	return sym.instantiatedFrom;
}

let _placedInstances: HashMap<Symbol, Symbol> = new HashMap<Symbol, Symbol>();

export function distinctInstances(order: Node[]): Node[] {
	const seen = new HashMap<Symbol, CheckedInstantiation[]>();
	const out: Node[] = [];
	for (const node of order) {
		const generic = instanceGenericOf(node);
		if (generic == null) throw new Error(`internal: a generic instance of this build has no generic it was made from`);
		const inst = checkedInstanceOf(node.resolvedSym!);
		let instances = seen.get(generic);
		if (instances == null) {
			instances = [];
			seen.set(generic, instances);
		}
		let placed: Symbol | null = null;
		for (const held of instances) {
			if (sameInstanceArgs(held.concreteTypes, inst.concreteTypes)) { placed = held.sym; break; }
		}
		if (placed != null) {
			_placedInstances.set(inst.sym, placed);
			continue;
		}
		_placedInstances.set(inst.sym, inst.sym);
		instances.push(inst);
		out.push(node);
	}
	return out;
}

export function placedInstanceOf(sym: Symbol): Symbol {
	return _placedInstances.get(sym) ?? sym;
}

function declaredClass(stmt: Node): Node | null {
	let n = stmt;
	if (n.kind == NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
	if (n != null && n.kind == NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
	return n != null && n.kind == NodeKind.ClassDecl ? n : null;
}

function placeBesideGeneric(stmts: Node[], instNode: Node): void {
	const generic = instanceGenericOf(instNode)!;
	let at = -1;
	for (let i = 0; i < stmts.length; i += 1) {
		const decl = declaredClass(stmts[i]);
		if (decl != null && decl == generic.declNode) { at = i + 1; break; }
	}
	if (at < 0) throw new Error(`internal: generic class '${generic.name}' of instance '${(instNode.data as ClassDeclData).className}' is not declared at the top level of ${generic.modulePath}`);
	while (at < stmts.length && stmts[at].kind == NodeKind.ClassDecl && instanceGenericOf(stmts[at]) == generic) at += 1;
	stmts.splice(at, 0, instNode);
}

export function placeInstance(stmts: Node[], instNode: Node, classesBesideGeneric: boolean): void {
	if (classesBesideGeneric && instNode.kind == NodeKind.ClassDecl) placeBesideGeneric(stmts, instNode);
	else stmts.push(instNode);
}

export function addPendingInstance(host: CheckerContext, node: Node): void {
	host.generatedInstances.push(node);
}

export function drainPendingInstances(moduleCtxs: CheckerContext[]): Node[] {
	const drained = new HashSet<CheckerContext>();
	const result: Node[] = [];
	for (const moduleCtx of moduleCtxs) {
		if (drained.has(moduleCtx)) continue;
		drained.add(moduleCtx);
		for (const node of moduleCtx.generatedInstances) result.push(node);
		moduleCtx.generatedInstances = [];
	}
	return result;
}

export function forgetInstances(ctx: CheckerContext): void {
	ctx.generatedInstances = [];
	ctx.procInstCache = new HashMap<Symbol, CheckedInstantiation[]>();
	ctx.typeInstCache = new HashMap<Symbol, CheckedInstantiation[]>();
}

// ===== Helpers =====

const _instanceLeft: Type[] = [];
const _instanceRight: Type[] = [];

function identityFlags(t: Type): BitSet<TypeFlag> {
	return t.typeFlags.excl(TypeFlag.HasAsgn).excl(TypeFlag.HasGenericParam).excl(TypeFlag.HasInheritedFields);
}

export function sameInstanceType(a: Type | null, b: Type | null): boolean {
	if (a == b) return true;
	if (a == null || b == null) return false;
	if (a.kind != b.kind) return sameType(a, b);
	if (identityFlags(a) != identityFlags(b)) return false;
	for (let i = 0; i < _instanceLeft.length; i += 1) {
		if (_instanceLeft[i] == a && _instanceRight[i] == b) return true;
	}
	_instanceLeft.push(a);
	_instanceRight.push(b);
	const result = sameInstanceTypeBody(a, b);
	_instanceLeft.pop();
	_instanceRight.pop();
	return result;
}

function sameInstanceTypeBody(a: Type, b: Type): boolean {
	if (a.kind == TypeKind.GenericInstance) {
		return sameInstanceType(a.typeExtra, b.typeExtra) && sameInstanceArgs(a.typeChildren, b.typeChildren);
	}
	if (isMaybeType(a) && isMaybeType(b)) return sameInstanceType(a.typeReturn, b.typeReturn);
	if (a.kind == TypeKind.Struct || a.kind == TypeKind.Enum || a.kind == TypeKind.Distinct) {
		if (a.sym != null || b.sym != null) {
			if (a.sym == null || a.sym != b.sym) return false;
			return !a.typeFlags.has(TypeFlag.DuVariant) || sameInstanceArgs(a.typeChildren, b.typeChildren);
		}
		if (a.typeFlags.has(TypeFlag.Spelled)) return a.typeName == b.typeName;
		if (a.typeName != "" || b.typeName != "") return false;
	}
	if (!sameType(a, b)) return false;
	if (!sameInstanceType(a.typeReturn, b.typeReturn)) return false;
	return sameInstanceArgs(a.typeChildren, b.typeChildren);
}

export function sameInstanceArgs(a: Type[], b: Type[]): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (!sameInstanceType(a[i], b[i])) return false;
	}
	return true;
}

function cachedInstance(cache: HashMap<Symbol, CheckedInstantiation[]>, generic: Symbol, types: Type[]): Symbol | null {
	const instances = cache.get(generic);
	if (instances == null) return null;
	for (const inst of instances) {
		if (sameInstanceArgs(inst.concreteTypes, types)) return inst.sym;
	}
	return null;
}

function cacheInstance(cache: HashMap<Symbol, CheckedInstantiation[]>, generic: Symbol, inst: Symbol, types: Type[]): void {
	let instances: CheckedInstantiation[] = [];
	const known = cache.get(generic);
	if (known != null) instances = known;
	const record: CheckedInstantiation = { sym: inst, concreteTypes: types };
	instances.push(record);
	_checkedInstances.set(inst, record);
	cache.set(generic, instances);
}

export function retainCheckedInstances(ctxs: CheckerContext[]): void {
	for (const ctx of ctxs) {
		for (const instances of ctx.procInstCache.values()) {
			for (const inst of instances) _checkedInstances.set(inst.sym, inst);
		}
		for (const instances of ctx.typeInstCache.values()) {
			for (const inst of instances) {
				_checkedInstances.set(inst.sym, inst);
				const ctor = ctorRoutineOf(inst.sym);
				if (ctor != null && ctor.instantiatedFrom != null && !_checkedInstances.has(ctor)) {
					_checkedInstances.set(ctor, { sym: ctor, concreteTypes: inst.concreteTypes });
				}
			}
		}
	}
}

// Deduplicate unify bindings (K=string may appear twice from HashMap<K,V> + K params)
function deduplicateBindings(names: string[], types: Type[]): { names: string[], types: Type[] } {
	const outNames: string[] = [];
	const outTypes: Type[] = [];
	for (let i = 0; i < names.length; i += 1) {
		if (i >= types.length) break;
		let dup = false;
		for (const n of outNames) { if (n == names[i]) { dup = true; break; } }
		if (!dup) {
			outNames.push(names[i]);
			outTypes.push(types[i]);
		}
	}
	return { names: outNames, types: outTypes };
}


// Add a type symbol to scope if not already present. Returns true if injected.
// Prefers caller's authoritative symbol type; falls back to provided type.
function tryInjectTypeSym(name: string, fallbackType: Type, ctx: CheckerContext, callerCtx: CheckerContext, injected: Symbol[]): boolean {
	if (lookupSymbol(ctx.table, name) != null) return false;
	const callerSym = lookupSymbol(callerCtx.table, name);
	const symType = callerSym != null ? callerSym.symbolType : fallbackType;
	const sym = newSym(ctx, SymbolKind.TypeAlias, name, symType);
	sym.nameId = getIdentId(ctx.table.identCache, name);
	addSymbolToScope(ctx.table.current, sym);
	injected.push(sym);
	return true;
}

function genericDeclType(instance: Type): Type {
	const base = instance.typeExtra != null ? unwrapRef(instance.typeExtra) : null;
	const decl = base != null ? base.sym : null;
	return decl != null && decl.symbolType != null ? decl.symbolType : instance;
}

function injectFieldTypeSyms(struct: Type, ctx: CheckerContext, callerCtx: CheckerContext, injected: Symbol[]): void {
	if (struct.typeChildren == null) return;
	for (const field of struct.typeChildren) injectConcreteTypeSyms(field, ctx, callerCtx, injected);
}

// Inject concrete type symbols into scope so resolveAnnotation finds them during re-check.
// For Array<Ref<Item>>, extracts "Item" and adds Ref<Struct("Item")> to scope.
// Reference parity (instantiateGenericParamList): concrete types added to scope.
function injectConcreteTypeSyms(t: Type | null, ctx: CheckerContext, callerCtx: CheckerContext, injected: Symbol[]): void {
	if (t == null) return;
	const tr = t.typeReturn;
	// Hand-rolled dispatch: match `when` guards don't propagate narrowing into
	// the arm body in the current binder, so we can't safely access `tr.kind`
	// inside `TypeKind.Ref when (tr !== null) => { ... tr.kind ... }`. The
	// if-chain below makes the narrowing scope explicit and matches the binder's
	// flow-based narrowing exactly.
	if (t.kind == TypeKind.Ref && tr != null) {
		if (tr.kind == TypeKind.Struct && tr.typeName != "") {
			if (tryInjectTypeSym(tr.typeName, t, ctx, callerCtx, injected)) injectFieldTypeSyms(tr, ctx, callerCtx, injected);
			return;
		}
		injectConcreteTypeSyms(tr, ctx, callerCtx, injected);
		return;
	}
	if (t.kind == TypeKind.Array && tr != null) {
		injectConcreteTypeSyms(tr, ctx, callerCtx, injected);
		return;
	}
	if (t.kind == TypeKind.Set && tr != null) {
		injectConcreteTypeSyms(tr, ctx, callerCtx, injected);
		return;
	}
	// Named user types — Struct (interface/class), Enum, Distinct (type alias).
	// Cross-module body re-check needs the concrete type symbol injected so
	// `resolveAnnotation("Color[]")` resolves to ColorArray instead of falling
	// back to Unknown → msRefArray. Without these, a helper
	// `function f<T>(...): T[] { const out: T[] = []; ... }` called with
	// T=Color emits the function signature mangled correctly but the body's
	// `out` declared as untyped msRefArray, breaking the assignment site at
	// C compile time.
	if (t.kind == TypeKind.Struct) {
		if (t.typeName == "" || tryInjectTypeSym(t.typeName, t, ctx, callerCtx, injected)) injectFieldTypeSyms(t, ctx, callerCtx, injected);
		return;
	}
	if (t.kind == TypeKind.EnumLiteral && tr != null) {
		injectConcreteTypeSyms(tr, ctx, callerCtx, injected);
		return;
	}
	if ((t.kind == TypeKind.Enum || t.kind == TypeKind.Distinct) && t.typeName != "") {
		tryInjectTypeSym(t.typeName, t, ctx, callerCtx, injected);
		return;
	}
	if (t.kind == TypeKind.GenericInstance) {
		if (t.typeName != "") tryInjectTypeSym(t.typeName, genericDeclType(t), ctx, callerCtx, injected);
		if (t.typeChildren != null) {
			for (const arg of t.typeChildren) injectConcreteTypeSyms(arg, ctx, callerCtx, injected);
		}
		return;
	}
	if (t.kind == TypeKind.Union) {
		if (t.typeName != "" && !tryInjectTypeSym(t.typeName, t, ctx, callerCtx, injected)) return;
		injectConcreteTypeSyms(t.typeExtra, ctx, callerCtx, injected);
		if (t.typeChildren != null) {
			for (const child of t.typeChildren) {
				injectConcreteTypeSyms(child, ctx, callerCtx, injected);
			}
		}
		return;
	}
	if (t.kind == TypeKind.Function) {
		injectConcreteTypeSyms(t.typeReturn, ctx, callerCtx, injected);
		if (t.typeChildren != null) {
			for (const param of t.typeChildren) {
				injectConcreteTypeSyms(param, ctx, callerCtx, injected);
			}
		}
		return;
	}
	if (t.kind == TypeKind.GenericInstance && t.typeChildren != null) {
		for (const child of t.typeChildren) {
			injectConcreteTypeSyms(child, ctx, callerCtx, injected);
		}
	}
}

function openInstanceScope(ctx: CheckerContext, params: Type[], types: Type[], outer: int32 = -1, declScope: Scope | null = null): Scope {
	const callerScope = ctx.table.current;
	let top = callerScope;
	while (top.scopeKind != ScopeKind.Module && top.parent != null) top = top.parent;
	ctx.table.current = declScope ?? top;
	openScope(ctx.table, ScopeKind.Block);
	for (let i = 0; i < params.length && i < types.length; i += 1) {
		if (i == outer) openScope(ctx.table, ScopeKind.Block);
		const sym = newSym(ctx, SymbolKind.TypeAlias, params[i].typeName, types[i]);
		sym.state = SymbolState.Shaped;
		sym.nameId = getIdentId(ctx.table.identCache, sym.name);
		addSymbolToScope(ctx.table.current, sym);
	}
	if (outer >= params.length) openScope(ctx.table, ScopeKind.Block);
	return callerScope;
}

interface RoutineBindings {
	b: UnifyBindings;
	outer: int32;
}

function ownerTypeParams(ctx: CheckerContext, sym: Symbol): Type[] {
	const owner = methodOwnerClass(ctx, sym);
	if (owner != null) return owner.typeParams;
	const decl = sym.declNode != null && sym.declNode.kind == NodeKind.DecoratedDecl ? (sym.declNode.data as DecoratedDeclData).decoratedNode : sym.declNode;
	if (decl == null || decl.kind != NodeKind.MethodDecl || sym.symbolType == null || sym.symbolType.typeChildren.length == 0) return [];
	const md = decl.data as MethodDeclDataLocal;
	if (md.methodParams.length == 0 || md.methodParams[0] != "this") return [];
	const found: Type[] = [];
	receiverTypeParams(sym.symbolType.typeChildren[0], found, new TypeVisitSet());
	return found;
}

function receiverTypeParams(t: Type | null, found: Type[], seen: TypeVisitSet): void {
	if (t == null || !typeVisitAdd(seen, t)) return;
	if (t.kind == TypeKind.GenericParam) {
		if (t.sym != null) found.push(t);
		return;
	}
	if (isDeclaredStruct(t)) {
		for (const gp of t.sym!.typeParams) receiverTypeParams(gp, found, seen);
		return;
	}
	for (const c of t.typeChildren) receiverTypeParams(c, found, seen);
	receiverTypeParams(t.typeReturn, found, seen);
}

function routineBindings(ctx: CheckerContext, sym: Symbol, params: Type[], types: Type[]): RoutineBindings {
	const given = createUnifyBindings();
	for (let i = 0; i < params.length && i < types.length; i += 1) {
		if (boundSlot(given, params[i]) < 0) bindParam(given, params[i], types[i]);
	}
	const out = createUnifyBindings();
	const taken: boolean[] = given.names.map((_n: string): boolean => false);
	const owner = ownerTypeParams(ctx, sym);
	for (const gp of owner) takeBound(out, given, taken, gp);
	const outer = out.names.length;
	for (const gp of sym.typeParams) takeBound(out, given, taken, gp);
	const declared = owner.length + sym.typeParams.length > 0;
	for (let i = 0; i < given.names.length; i += 1) {
		if (!taken[i] && !declared) bindAt(out, given, i);
	}
	return { b: out, outer: outer };
}

function takeBound(out: UnifyBindings, given: UnifyBindings, taken: boolean[], gp: Type): void {
	const at = boundSlot(given, gp);
	if (at < 0 || taken[at]) return;
	taken[at] = true;
	bindAt(out, given, at);
}

function removeInjectedSyms(ctx: CheckerContext, injected: Symbol[]): void {
	for (const sym of injected) {
		// Each injected sym has a real nameId (set in injectConcreteTypeSyms before push);
		// O(1) removal by key instead of linear-scan-swap-pop.
		if (sym.nameId != 0) {
			ctx.table.current.symbols.delete(sym.nameId);
		}
	}
}

// Nim `mixin` semantics for convention protocols (docs/PROTOCOLS.md Part II):
// the instantiating module's extensions are visible while the generic body is
// re-checked in the defining module's ctx, then removed. Exported only — the
// instance is emitted in the defining module's TU, so a private extension
// would resolve here but fail at link; skipping it surfaces a check-time
// "no member" error with the instantiation note instead.
function injectCallerExtensions(bodyCtx: CheckerContext, ctx: CheckerContext): int32 {
	if (bodyCtx == ctx) return -1;
	if (bodyCtx.extensionRegistry == null || ctx.extensionRegistry == null) return -1;
	const preCount = bodyCtx.extensionRegistry.methods.length;
	for (const m of ctx.extensionRegistry.methods) {
		// Drop only KNOWN-private extensions of the instantiating module itself.
		// Import-derived entries are exported by construction but their local
		// sym view does NOT carry the Exported flag — discriminate by the sym's
		// defining modulePath instead of the flag alone.
		if (m.sym != null
				&& (m.sym.modulePath == "" || m.sym.modulePath == ctx.modulePath)
				&& !hasFlag(m.sym, SymbolFlag.Exported)) {
			continue;
		}
		registerExtension(bodyCtx.extensionRegistry, m);
	}
	return preCount;
}

function truncateCallerExtensions(bodyCtx: CheckerContext, preCount: int32): void {
	if (preCount < 0) return;
	truncateExtensions(bodyCtx.extensionRegistry, preCount);
}

function displayTypeArgs(types: Type[]): string {
	if (types.length == 0) return "";
	let s = "<";
	for (let i = 0; i < types.length; i += 1) {
		if (i > 0) s = s + ", ";
		s = s + typeDisplayName(types[i]);
	}
	return s + ">";
}


// Unwrap ExportDecl/DecoratedDecl to get the inner FunctionDecl. For class
// methods (static OR instance) synthesize an equivalent FunctionDecl from the
// MethodDecl so the existing instantiation flow drives mono on it. Instance
// methods already carry `this` as param 0 (prepended in collectClassMethod).
function unwrapToFunctionDecl(node: Node): Node {
	if (node == null) return null as unknown as Node;
	let n = node;
	if (n.kind == NodeKind.ExportDecl) n = (n.data as ExportDeclData).exportedDecl;
	if (n != null && n.kind == NodeKind.DecoratedDecl) n = (n.data as DecoratedDeclData).decoratedNode;
	if (n != null && n.kind == NodeKind.FunctionDecl) return n;
	if (n != null && n.kind == NodeKind.MethodDecl) {
		const md = n.data as MethodDeclDataLocal;
		// Synthesize a FunctionDecl-shaped Node mirroring this method. The class
		// name is woven in through the symbol's name (set by collectMethodMember
		// as `${className}_${methodName}`) — mangleMonoName uses sym.name, so no
		// need to repeat the prefix here.
		const fnData: NodeData = {
			fnName: md.methodName,
			params: md.methodParams,
			fnParamTypes: md.methodParamTypes,
			fnBody: md.methodBody,
			fnFlags: md.methodFlags,
			fnReturnType: md.methodReturnType,
			fnDefaults: md.methodDefaults,
			nativeName: md.nativeName,
			nameLocation: md.nameLocation,
		};
		const synth = createNodeAt(NodeKind.FunctionDecl, fnData, n.location);
		synth.nodeType = n.nodeType;
		return synth;
	}
	return null as unknown as Node;
}

const SYNTAX_NODE_FLAGS: BitSet<NodeFlag> = NodeFlag.QuoteSplice | NodeFlag.BoundSym | NodeFlag.StaticStorage | NodeFlag.ExportDefault | NodeFlag.ExternC | NodeFlag.Converter | NodeFlag.WhenDeferred | NodeFlag.ExplicitDeref | NodeFlag.OptionalChainEnd;

function isCheckerWrapper(node: Node): boolean {
	if (node.kind == NodeKind.HiddenDeref) return !node.flags.has(NodeFlag.ExplicitDeref);
	return node.kind == NodeKind.HiddenAddr || node.kind == NodeKind.HiddenStdConv || node.kind == NodeKind.HiddenSubConv;
}

// ===== clearCheckerState =====
// Collapse checker-inserted wrappers and clear resolvedSym/flags on a
// cloned AST so the re-check regenerates them against concrete types. forEachChild drives
// the recursion so EVERY NodeKind is covered — a manual match silently missed ForStmt/Switch/
// Match etc., stacking a second deref on loop/array accesses in instantiated method bodies.
export function clearCheckerState(node: Node): void {
	if (node == null) return;
	const redeclared: Symbol[] = [];
	collectDeclaredSyms(node, redeclared);
	clearStateKeepingOuterBindings(node, redeclared);
}

function collectDeclaredSyms(node: Node, into: Symbol[]): void {
	const binds = node.kind == NodeKind.VariableDecl || node.kind == NodeKind.ForOfStmt || node.kind == NodeKind.TryCatchStmt;
	if (binds && node.resolvedSym != null) into.push(node.resolvedSym);
	if (node.paramSyms != null) for (const p of node.paramSyms) into.push(p);
	forEachChild(node, (child: Node): void => { if (child != null) collectDeclaredSyms(child, into); });
}

function bindsInto(node: Node, redeclared: Symbol[]): boolean {
	for (const s of redeclared) { if (node.resolvedSym == s) return true; }
	return false;
}

function clearStateKeepingOuterBindings(node: Node, redeclared: Symbol[]): void {
	if (node == null) return;
	while (isCheckerWrapper(node)) {
		const inner = node.kind == NodeKind.HiddenStdConv || node.kind == NodeKind.HiddenSubConv
			? (node.data as HiddenStdConvData).convExpr
			: (node.data as HiddenDerefData).expr;
		if (inner == null) break;
		node.kind = inner.kind;
		node.data = inner.data;
		node.nodeType = inner.nodeType;
		if (inner.flags.has(NodeFlag.ExplicitDeref)) node.flags = node.flags.incl(NodeFlag.ExplicitDeref);
	}
	// Enum member access is a mangled Identifier ("E_M") whose name is never bound
	// in scope — resolvedSym is its ONLY resolution path (checkExprPass honors it,
	// clone.ms preserves it). The enum member type is concrete, never generic, so
	// it needs no regeneration against the instance's concrete types. Keep it.
	// See NIM-REF CK-22 "Enum member repr & generic-instantiation survival".
	const rebinds = node.kind == NodeKind.Identifier && node.flags.has(NodeFlag.BoundSym) && bindsInto(node, redeclared);
	if (rebinds) node.flags = node.flags.excl(NodeFlag.BoundSym);
	const keepBound = node.flags.has(NodeFlag.BoundSym) && node.resolvedSym != null;
	if (!keepBound && (node.resolvedSym == null || node.resolvedSym.symbolKind != SymbolKind.EnumMember)) {
		node.resolvedSym = null;
	}
	node.flags = node.flags.intersection(SYNTAX_NODE_FLAGS);
	forEachChild(node, (child: Node): void => { clearStateKeepingOuterBindings(child, redeclared); });
}

// ===== replaceTypeVars =====
// Walk every node in the cloned body and substitute GenericParam types with
// concrete types on nodeType plus any string-form annotations.
//
// Reference parity: replaceTypeVarsN iterates all children uniformly.
// We delegate child enumeration to forEachChild (the canonical walker in
// src/ast/visitor.ms) so every NodeKind is covered by construction — adding a
// new NodeKind cannot silently break generic instantiation.

// Does NOT descend into children — that's forEachChild's job.
function substNodeLocal(node: Node, params: Type[], concreteTypes: Type[]): void {
	if (node.nodeType != null && params.length > 0) node.nodeType = substituteParams(node.nodeType, params, concreteTypes);
}

export function replaceTypeVars(node: Node, params: Type[], concreteTypes: Type[]): void {
	if (node == null) return;
	substNodeLocal(node, params, concreteTypes);
	forEachChild(node, (child: Node): void => { replaceTypeVars(child, params, concreteTypes); });
}

// ===== On-Demand Instantiation =====

export function declareLocalGeneric(sym: Symbol, declScope: Scope): void {
	_localGenerics.set(sym, declScope);
	_localInstances.set(sym, []);
}

export function takeLocalInstances(sym: Symbol): Node[] | null {
	const placed = _localInstances.get(sym);
	if (placed == null) return null;
	_localGenerics.delete(sym);
	_localInstances.delete(sym);
	return placed;
}

function instantiateLocalGeneric(ctx: CheckerContext, sym: Symbol, name: string, routine: RoutineBindings, host: CheckerContext, declScope: Scope): Symbol {
	const cloned = monoCloneNode(unwrapToFunctionDecl(sym.declNode)!);
	const cd = cloned.data as FunctionDeclData;
	cd.fnName = name;
	cd.fnFlags = stripGenFlag(cd.fnFlags);
	clearCheckerState(cd.fnBody);
	bindFunctionFlow(cloned, cd.fnBody);
	const callerScope = openInstanceScope(ctx, routine.b.params, routine.b.types, routine.outer, declScope);
	const instSym = callCheckLocalInstance(ctx, cloned, (declared: Symbol): void => {
		declared.instantiatedFrom = sym;
		cacheInstance(host.procInstCache, sym, declared, routine.b.types);
	});
	ctx.table.current = callerScope;
	if (instSym == null) throw new Error(`internal: the instance '${name}' of local generic '${sym.name}' declared no symbol`);
	_localInstances.get(sym)!.push(cloned);
	return instSym;
}

let _igfCalls: int64 = 0;
let _igfHits: int64 = 0;
let _igfMisses: int64 = 0;
let _igfTime: float64 = 0;
let _igfBodyTime: float64 = 0;
export function instantiateProfile(): int64[] {
	return [_igfCalls, _igfHits, _igfMisses];
}
export function instantiateTimings(): float64[] {
	return [_igfTime, _igfBodyTime];
}

export function instantiateGenericFunction(sym: Symbol, params: Type[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation): Symbol {
	if (ctx.genericInstDepth > 50) {
		addError(ctx, "generic instantiation too nested: instantiating '" + sym.name + "' goes deeper than 50 nested instantiations", callLoc.line, callLoc.column);
		return null as unknown as Symbol;
	}
	_igfCalls = _igfCalls + 1;

	// Extern/ImportC generic functions are handled by the C runtime (nativeName binding).
	// Don't instantiate — the runtime provides the implementation.
	if (hasFlag(sym, SymbolFlag.ImportC)) return null as unknown as Symbol;
	if (sym.nativeName != "") return null as unknown as Symbol;

	// Reference parity: refuse to instantiate if any type arg
	// is still a GenericParam (inference didn't complete). Unknown is allowed
	// through because `unknown` is a real user-facing concrete type (TS parity:
	// type-erased handles like `type HostNode = unknown`), represented as void*
	// in C. Blocking Unknown here forced callers to fall back to a wrong cached
	// instance — see nullableFunction.ms regression coverage.
	for (const ct of concreteTypes) {
		if (ct == null || hasGenericParams(ct)) {
			return null as unknown as Symbol;
		}
	}

	ctx.genericInstDepth = ctx.genericInstDepth + 1;

	const routine = routineBindings(ctx, sym, params, concreteTypes);
	const dedup = routine.b;
	const host = ctx.instantiatingCtx != null ? ctx.instantiatingCtx : ctx;
	const existing = cachedInstance(host.procInstCache, sym, dedup.types);
	if (existing != null) {
		ctx.genericInstDepth = ctx.genericInstDepth - 1;
		_igfHits = _igfHits + 1;
		return existing;
	}

	// Extension method disambiguation: two overloads with the same function name and
	// generic arity (e.g. `set<K,V>(this Map<K,V>)` and `set<K,V>(this HashMap<K,V>)`)
	// produce distinct mangled names. Without this prefix, `set__string_int32` collides
	// across Map and HashMap, and the later instantiation overwrites the earlier one.
	// Prefix with the receiver class name (e.g. `Map_set__string_int32`).
	let mangleBase = sym.name;
	if (sym.declNode != null && sym.declNode.kind == NodeKind.FunctionDecl) {
		const fd = sym.declNode.data as FunctionDeclData;
		if (isExtensionFlag(fd.fnFlags)) {
			const recv = getExtReceiverType(fd.fnFlags);
			if (recv != "") mangleBase = recv + "_" + sym.name;
		}
	}
	const mangledName = mangleMonoName(monoRoutineBaseName(mangleBase, sym.modulePath, sym.disamb), dedup.types);


	const declScope = _localGenerics.get(sym);
	if (declScope != null) {
		const local = instantiateLocalGeneric(ctx, sym, mangledName, routine, host, declScope);
		ctx.genericInstDepth = ctx.genericInstDepth - 1;
		return local;
	}

	const bodyCtx = pickBodyCtx(sym.modulePath, ctx, sym);
	const _ig0 = performance.now();
	_igfMisses = _igfMisses + 1;
	const fnNode = unwrapToFunctionDecl(sym.declNode);
	if (fnNode == null) {
		ctx.genericInstDepth = ctx.genericInstDepth - 1;
		return null as unknown as Symbol;
	}

	// Clone AST + substitute annotations.
	// replaceTypeVars handles the top-level FunctionDecl's fnParamTypes/fnReturnType
	// (via substNodeLocal) and walks the body via forEachChild.
	const cloned = monoCloneNode(fnNode);
	const cd = cloned.data as FunctionDeclData;
	replaceTypeVars(cloned, dedup.params, dedup.types);

	// Rename + strip flags
	cd.fnName = mangledName;
	// Preserve generator flag — generatorLower needs it after instantiation.
	// Strip gen: (type params) and ext: (extension metadata) but keep generator/async.
	cd.fnFlags = stripGenFlag(cd.fnFlags);

	const instType = sym.symbolType != null ? substituteBound(sym.symbolType, dedup) : sym.symbolType;
	cloned.nodeType = instType;

	// Create and register symbol in root scope.
	// Instance is OWNED by the generic's defining module (reference parity:
	// generateInstance setOwner(result, fn)). It is emitted in that module's TU, so the
	// generic body's module-private helpers (static functions, lifted closures) are visible
	// to it — co-location, not cross-TU. The mangled C name becomes module-qualified
	// (`gen__int32__<M>`) via mangledFunctionName; DCE/dedup predicates still key on the
	// unqualified `fnName` containing `__`. Used-but-not-defining modules forward-decl it
	// through the standard cross-module proto path.
	const instSym = makeSymbol(mangledName, SymbolKind.Function, instType, false);
	instSym.state = SymbolState.Shaped;
	instSym.nativeName = "";
	instSym.builtinKind = sym.builtinKind;
	instSym.modulePath = sym.modulePath != "" ? sym.modulePath : ctx.modulePath;
	stampItem(bodyCtx, instSym);
	instSym.declNode = cloned;
	instSym.nameId = getIdentId(host.table.identCache, mangledName);
	instSym.instantiatedFrom = sym;
	if (hasFlag(sym, SymbolFlag.Borrow)) setFlag(instSym, SymbolFlag.Borrow);
	if (isAsyncFunctionNode(cloned)) setFlag(instSym, SymbolFlag.Async);
	cacheInstance(host.procInstCache, sym, instSym, dedup.types);
	cloned.resolvedSym = instSym;

	// Reference parity (semProcBody): check body in the DEFINING module's scope
	// (for private helpers like mapRawGet), but with concrete type symbols injected so
	// user types (Item, Foo, etc.) are visible during type annotation resolution.
	if (cd.fnBody != null && !hasFlag(sym, SymbolFlag.Borrow)) {
		const savedHost = bodyCtx.instantiatingCtx;
		bodyCtx.instantiatingCtx = host;
		const savedModulePath = bodyCtx.modulePath;
		bodyCtx.modulePath = ctx.modulePath;
		// Reference parity (instantiateGenericParamList): inject concrete type
		// symbols into scope so resolveAnnotation("Item") finds the user type during re-check.
		// Without this, HashMap<string, Item[]> methods resolve "Item" to Unknown.
		const callerScope = openInstanceScope(bodyCtx, dedup.params, dedup.types, routine.outer);
		bodyCtx.table.current.friendModules.push(sym.modulePath);
		bodyCtx.table.current.privateAccess = methodOwnerClass(bodyCtx, sym);
		const injectedSyms: Symbol[] = [];
		for (const ct of dedup.types) {
			injectConcreteTypeSyms(ct, bodyCtx, ctx, injectedSyms);
		}
		const extPreCount = injectCallerExtensions(bodyCtx, ctx);
		const errBefore = bodyCtx.errors.length;
		// Strip stale HiddenDeref/resolvedSym from the clone so re-check regenerates them
		// against concrete types — a class-method body already checked once (this: Class<T>
		// is a Ref) otherwise keeps its deref and the re-check stacks a second one.
		clearCheckerState(cd.fnBody);
		bindFunctionFlow(cloned, cd.fnBody);
		// Mirror checkFunctionDecl's return-inference setup: seed inferredReturn
		// from the instance type. checkFunctionBody does NOT reset it — without
		// this the body's returns mutate a stale slot and an un-annotated return
		// stays Inferred into codegen (C: internal error kind=48, JS: <object>).
		const savedReturn = bodyCtx.inferredReturn;
		const savedReturnStmts = bodyCtx.inferredReturnStmts;
		bodyCtx.inferredReturn = instType.typeReturn != null ? instType.typeReturn : inferredType();
		bodyCtx.inferredReturnStmts = [];
		const _igb0 = performance.now();
		const outerGensym = beginGensymUnit();
		cloned.paramSyms = callCheckFunctionBody(bodyCtx, instSym, cd.params, cd.fnBody, null);
		rewindTemplateGensym(outerGensym);
		checkRoutineBorrows(bodyCtx, cloned);
		_igfBodyTime = _igfBodyTime + (performance.now() - _igb0);
		// Mirror the decl-side apply: an unresolved (un-annotated) return
		// adopts the body's inferred return so the instance is fully typed.
		if (instType.kind == TypeKind.Function
				&& instType.typeReturn != null
				&& isUnresolvedType(instType.typeReturn)
				&& isSyncGeneratorFlags(cd.fnFlags)) {
			instType.typeReturn = settleYields(bodyCtx, sym.name, cd.nameLocation);
		} else if (instType.kind == TypeKind.Function
				&& instType.typeReturn != null
				&& isUnresolvedType(instType.typeReturn)) {
			if (bodyCtx.inferredReturn.kind != TypeKind.Inferred) {
				instType.typeReturn = bodyCtx.inferredReturn;
				for (const rs of bodyCtx.inferredReturnStmts) {
					const rsd = rs.data as ReturnStmtData;
					if (rsd.argument != null) rsd.argument = fitJoinedBranch(bodyCtx, rsd.argument, bodyCtx.inferredReturn);
				}
			} else {
				instType.typeReturn = voidType();
			}
		}
		if (cd.fnReturnType == "" && isLifecycleHookName(sym.name) && getExtReceiverType(cd.fnFlags) != "") {
			refuseHookInferredReturn(bodyCtx, sym.name, cd.nameLocation, instType);
		}
		bodyCtx.inferredReturn = savedReturn;
		bodyCtx.inferredReturnStmts = savedReturnStmts;
		if (bodyCtx != ctx && bodyCtx.errors.length > errBefore) {
			addError(ctx, "in instantiation of '" + sym.name + displayTypeArgs(dedup.types) + "': " + bodyCtx.errors[errBefore].message, callLoc.line, callLoc.column);
			while (bodyCtx.errors.length > errBefore) bodyCtx.errors.pop();
		}
		bodyCtx.modulePath = savedModulePath;
		bodyCtx.instantiatingCtx = savedHost;
		// Clean up injected symbols to avoid polluting prelude scope
		removeInjectedSyms(bodyCtx, injectedSyms);
		bodyCtx.table.current = callerScope;
		truncateCallerExtensions(bodyCtx, extPreCount);
	}

	addPendingInstance(host, cloned);
	if (instType != null && instType.kind == TypeKind.Function) {
		for (const pt of instType.typeChildren) instantiateHooksInType(pt, ctx, callLoc, 0);
		instantiateHooksInType(instType.typeReturn, ctx, callLoc, 0);
	}

	ctx.genericInstDepth = ctx.genericInstDepth - 1;
	_igfTime = _igfTime + (performance.now() - _ig0);
	return instSym;
}

function instanceFieldType(instStruct: Type, fieldName: string): Type | null {
	for (let i = 0; i < instStruct.typeNames.length; i += 1) {
		if (instStruct.typeNames[i] == fieldName && i < instStruct.typeChildren.length) return instStruct.typeChildren[i];
	}
	return null;
}

function instanceFieldInits(classData: ClassDeclData, params: Type[], types: Type[], instStruct: Type, classSym: Symbol, ctx: CheckerContext, loc: SourceLocation): Node[] {
	const fields: Node[] = [];
	let initialized = 0;
	for (const raw of classData.classBody) {
		const member = raw.kind == NodeKind.DecoratedDecl ? (raw.data as DecoratedDeclData).decoratedNode : raw;
		if (member == null || member.kind != NodeKind.PropertyDecl) continue;
		const pd = member.data as PropertyDeclData;
		if (pd.propIsStatic) continue;
		const fieldType = instanceFieldType(instStruct, pd.propName);
		if (fieldType == null) {
			addError(ctx, "internal: field '" + pd.propName + "' of generic class '" + classSym.name + "' has no slot in its instance '" + instStruct.typeName + "'", loc.line, loc.column);
			continue;
		}
		const field = monoCloneNode(member);
		replaceTypeVars(field, params, types);
		field.nodeType = fieldType;
		fields.push(field);
		if (pd.propInitializer != null) initialized += 1;
	}
	if (initialized == 0) return fields;
	const bodyCtx = pickBodyCtx(classSym.modulePath, ctx, classSym);
	const savedModulePath = bodyCtx.modulePath;
	bodyCtx.modulePath = classSym.modulePath != "" ? classSym.modulePath : ctx.modulePath;
	const callerScope = openInstanceScope(bodyCtx, params, types);
	bodyCtx.table.current.privateAccess = classSym;
	const injectedSyms: Symbol[] = [];
	for (const ct of types) {
		injectConcreteTypeSyms(ct, bodyCtx, ctx, injectedSyms);
	}
	const extPreCount = injectCallerExtensions(bodyCtx, ctx);
	const errBefore = bodyCtx.errors.length;
	for (const field of fields) {
		const fpd = field.data as PropertyDeclData;
		if (fpd.propInitializer == null) continue;
		clearCheckerState(fpd.propInitializer);
		callCheckExpr(bodyCtx, fpd.propInitializer, field.nodeType);
		if (fpd.propInitializer.nodeType != null) {
			fpd.propInitializer = fitNode(bodyCtx, fpd.propInitializer, field.nodeType, fpd.propInitializer.nodeType);
		}
	}
	if (bodyCtx != ctx && bodyCtx.errors.length > errBefore) {
		addError(ctx, "in instantiation of '" + classSym.name + displayTypeArgs(types) + "': " + bodyCtx.errors[errBefore].message, loc.line, loc.column);
	}
	bodyCtx.modulePath = savedModulePath;
	removeInjectedSyms(bodyCtx, injectedSyms);
	bodyCtx.table.current = callerScope;
	truncateCallerExtensions(bodyCtx, extPreCount);
	return fields;
}

function canonicalInstance(base: Type, typeArgs: Type[], classSym: Symbol): Type {
	const inst = createGenericInstance(base, typeArgs);
	instantiateGenericBody(inst, symGenericParams(classSym));
	return inst;
}

// ===== Field initializers of an object literal =====
// An object literal of a class type takes the initializer of every field it omits, the way
// `new C()` runs it: a fresh copy re-checked in the class's module, at the field's type.

function classDeclOf(classSym: Symbol): Node {
	const decl = classSym.declNode;
	if (decl == null || decl.kind != NodeKind.ClassDecl) throw new Error(`internal: class '${classSym.name}' reached field initialization without its declaration`);
	return decl;
}

function ownField(decl: Node, fieldName: string): PropertyDeclData | null {
	for (const raw of (decl.data as ClassDeclData).classBody) {
		const member = raw.kind == NodeKind.DecoratedDecl ? (raw.data as DecoratedDeclData).decoratedNode : raw;
		if (member == null || member.kind != NodeKind.PropertyDecl) continue;
		const pd = member.data as PropertyDeclData;
		if (!pd.propIsStatic && pd.propName == fieldName) return pd;
	}
	return null;
}

function readsThis(node: Node): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.Identifier && (node.data as IdentifierData).name == "this") return true;
	let found = false;
	forEachChild(node, (child: Node): void => { if (!found && readsThis(child)) found = true; });
	return found;
}

export function literalFieldInitializer(ctx: CheckerContext, classType: Type | null, fieldName: string, fieldType: Type, loc: SourceLocation): Node | null {
	let cur = classType;
	for (let depth = 0; cur != null && depth < 16; depth += 1) {
		const body = cur.kind == TypeKind.Ref && cur.typeReturn != null ? cur.typeReturn : cur;
		const classSym = runtimeClassSym(body);
		if (classSym == null) return null;
		const decl = classDeclOf(classSym);
		const pd = ownField(decl, fieldName);
		if (pd != null) {
			if (pd.propInitializer == null) return null;
			if (readsThis(pd.propInitializer)) {
				addError(ctx, `field '${fieldName}' of '${classSym.name}' has an initializer that reads 'this', which an object literal cannot run — give '${fieldName}' a value in the literal`, loc.line, loc.column);
				return null;
			}
			const params = body.kind == TypeKind.GenericInstance ? classSym.typeParams : [];
			const types = body.kind == TypeKind.GenericInstance ? body.typeChildren : [];
			return checkFieldInitializerCopy(ctx, pd.propInitializer, fieldName, fieldType, classSym, params, types, loc);
		}
		cur = classParentOf(body);
	}
	return null;
}

function checkFieldInitializerCopy(ctx: CheckerContext, init: Node, fieldName: string, fieldType: Type, classSym: Symbol, params: Type[], types: Type[], loc: SourceLocation): Node {
	let copy = monoCloneNode(init);
	clearCheckerState(copy);
	if (params.length > 0) replaceTypeVars(copy, params, types);
	const bodyCtx = pickBodyCtx(classSym.modulePath, ctx, classSym);
	const savedModulePath = bodyCtx.modulePath;
	bodyCtx.modulePath = classSym.modulePath != "" ? classSym.modulePath : ctx.modulePath;
	const callerScope = openInstanceScope(bodyCtx, params, types);
	bodyCtx.table.current.privateAccess = classSym;
	const injectedSyms: Symbol[] = [];
	for (const ct of types) injectConcreteTypeSyms(ct, bodyCtx, ctx, injectedSyms);
	const extPreCount = injectCallerExtensions(bodyCtx, ctx);
	const errBefore = bodyCtx.errors.length;
	callCheckExpr(bodyCtx, copy, fieldType);
	if (copy.nodeType != null) copy = fitNode(bodyCtx, copy, fieldType, copy.nodeType);
	if (bodyCtx.errors.length > errBefore) {
		const first = bodyCtx.errors[errBefore].message;
		bodyCtx.errors.shrink(errBefore);
		addError(ctx, `the initializer of field '${fieldName}' of '${classSym.name}', run for this literal: ${first}`, loc.line, loc.column);
	}
	bodyCtx.modulePath = savedModulePath;
	removeInjectedSyms(bodyCtx, injectedSyms);
	bodyCtx.table.current = callerScope;
	truncateCallerExtensions(bodyCtx, extPreCount);
	return copy;
}

// ===== On-Demand Constructor Instantiation =====
// Reference parity: on-demand proc instantiation (same pattern as standard generateInstance).
// For classes with constructors, we generate a standalone FunctionDecl named ClassName_new.

export function instantiateClassConstructor(classSym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): Symbol | null {
	// Refuse unresolved types
	for (const ct of concreteTypes) {
		if (ct == null || ct.kind == TypeKind.GenericParam || isUnresolvedType(ct)) return null;
	}

	const dedup = deduplicateBindings(paramNames, concreteTypes);
	const params = declaredTypeParams(classSym, dedup.names.length);
	const host = ctx.instantiatingCtx != null ? ctx.instantiatingCtx : ctx;
	const existing = cachedInstance(host.typeInstCache, classSym, dedup.types);
	if (existing != null) return existing;
	const mangledClass = monoInstanceNameOf(classSym.name, classSym.modulePath, dedup.types);
	const bodyCtx = pickBodyCtx(classSym.modulePath, ctx, classSym);

	const classDeclNode = classSym.declNode;
	if (classDeclNode == null || classDeclNode.kind != NodeKind.ClassDecl) {
		addError(ctx, `internal: class '${classSym.name}' reached constructor instantiation without its declaration`, classSym.location.line, classSym.location.column);
		return null;
	}
	const classData = classDeclNode.data as ClassDeclData;
	let ctorNode: Node | null = null;
	for (const member of classData.classBody) {
		if (member.kind == NodeKind.ConstructorDecl) { ctorNode = member; }
	}
	const loc = ctorNode != null && ctorNode.location != null ? ctorNode.location : (classDeclNode.location != null ? classDeclNode.location : makeLoc(0, 0));
	const structBase = unwrapClassStruct(classSym);
	const canonical = canonicalInstance(structBase, concreteTypes, classSym);
	const parent = classParentOf(canonical);
	const substStruct = instanceStruct(structBase, mangledClass, params, dedup.types);
	substStruct.typeExtra = parent;
	const concreteClassType = createRef(substStruct);
	const instSym = newSym(bodyCtx, SymbolKind.Class, mangledClass, concreteClassType);
	instSym.state = SymbolState.Shaped;
	instSym.symFlags = classSym.symFlags;
	instSym.modulePath = classSym.modulePath != "" ? classSym.modulePath : ctx.modulePath;
	instSym.location = classSym.location;
	instSym.nameId = getIdentId(host.table.identCache, mangledClass);
	instSym.instantiatedFrom = classSym;
	substStruct.sym = instSym;
	cacheInstance(host.typeInstCache, classSym, instSym, dedup.types);
	const classBody: Node[] = instanceFieldInits(classData, params, dedup.types, substStruct, classSym, ctx, loc);
	if (ctorNode != null) classBody.push(instanceCtorDecl(ctorNode, classSym, instSym, params, dedup.types, mangledClass, createRef(canonical), ctx, loc));
	// Set classNode.nodeType to the concrete (instantiated) class type so the
	// methodToFunction transform can pull the right receiver type when lifting
	// the ctor — without it, `this` falls back to `void*` in the generated
	// `<MangledClass>_init` signature and `(*this).field` accesses fail to type
	// check at the C level.
	const classNodeData: NodeData = { className: mangledClass, classDisplayName: typeDisplayName(canonical), classExtends: parent != null ? typeDisplayName(parent) : "", classBody, nameLocation: loc, classImplements: [] };
	const classNode = createNodeAt(NodeKind.ClassDecl, classNodeData, loc);
	classNode.nodeType = concreteClassType;
	classNode.resolvedSym = instSym;
	instSym.declNode = classNode;
	addPendingInstance(host, classNode);
	instantiateParentClass(parent, ctx);
	instantiateInstanceHooks(structBase.sym != null ? structBase.sym : classSym, classData, mangledClass, params, dedup.types, ctx, loc);
	const instType = createGenericInstance(structBase, dedup.types);
	instType.typeName = classSym.name;
	instantiateHooksInType(instType, ctx, loc, 0);
	return instSym;
}

export function instantiateParentClass(parent: Type | null, ctx: CheckerContext): Symbol | null {
	const body = parent != null && parent.kind == TypeKind.Ref ? parent.typeReturn : parent;
	if (body == null || body.kind != TypeKind.GenericInstance || hasGenericParams(body)) return null;
	const cls = runtimeClassSym(body);
	if (cls == null) return null;
	const names = splitTopLevel(genericParamNamesOf(symGenericParams(cls)), ",").map((n: string): string => n.trim());
	return instantiateClassConstructor(cls, names, body.typeChildren, ctx);
}

function unwrapClassStruct(classSym: Symbol): Type {
	const t = classSym.symbolType;
	return t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
}

// Mono receiver: Ref<Struct{substituted fields}> named `mangledClass`. genClassDecl
// reads non-static fields from node.nodeType's struct (typeNames/typeChildren); a
// Ref<GenericInstance> peels to type-args not fields → an empty struct in the ctor's TU.
function instanceStruct(structBase: Type, mangledClass: string, params: Type[], types: Type[]): Type {
	let substStruct: Type = substituteParams(structBase, params, types);
	if (substStruct == structBase) {
		const newNames: string[] = [];
		for (const n of substStruct.typeNames) newNames.push(n);
		const newChildren: Type[] = [];
		for (const c of substStruct.typeChildren) newChildren.push(c);
		return createStruct(mangledClass, newNames, newChildren, isStructType(substStruct));
	}
	substStruct.typeName = mangledClass;
	return substStruct;
}

function instanceCtorDecl(ctorNode: Node, classSym: Symbol, instSym: Symbol, params: Type[], types: Type[], mangledClass: string, thisType: Type, ctx: CheckerContext, loc: SourceLocation): Node {
	const ctorData = ctorNode.data as ConstructorDeclData;

	// Clone the constructor body
	const clonedBody = ctorData.ctorBody != null ? monoCloneNode(ctorData.ctorBody) : null as unknown as Node;

	const fnParams: string[] = [];
	const fnParamTypes: string[] = [];
	for (const p of ctorData.ctorParams) { fnParams.push(p); }
	for (const pt of ctorData.ctorParamTypes) { fnParamTypes.push(pt); }

	// Substitute type vars in body
	if (clonedBody != null) {
		replaceTypeVars(clonedBody, params, types);
	}

	// Clone constructor defaults (for default-fill at call sites)
	const fnDefaults: Node[] = [];
	if (ctorData.ctorDefaults != null) {
		for (const d of ctorData.ctorDefaults) {
			fnDefaults.push(d != null ? monoCloneNode(d) : null as unknown as Node);
		}
	}

	const clonedCtor: NodeData = { ctorParams: fnParams, ctorParamTypes: fnParamTypes, ctorBody: clonedBody, ctorDefaults: fnDefaults, ctorVisibility: ctorData.ctorVisibility };
	const ctorDeclNode = createNodeAt(NodeKind.ConstructorDecl, clonedCtor, loc);

	if (ctorNode.resolvedSym == null) throw new Error(`internal: generic constructor '${classSym.name}' has no routine symbol`);
	const formals = ctorFormalTypes(ctorNode.resolvedSym);
	if (formals == null) throw new Error(`internal: generic constructor '${classSym.name}' has no routine type`);
	const resolvedParamTypes = formals.map((t: Type): Type => substituteParams(t, params, types));
	ctorDeclNode.nodeType = createFunction(resolvedParamTypes, fnParams, null as unknown as Type);

	const host = ctx.instantiatingCtx != null ? ctx.instantiatingCtx : ctx;
	const bodyCtx = pickBodyCtx(classSym.modulePath, ctx, classSym);
	const ctorSym = mintCtorRoutine(bodyCtx, instSym, mangledClass, thisType, resolvedParamTypes, fnParams, ctorDeclNode, fnDefaults);
	ctorSym.state = SymbolState.Checked;
	ctorSym.instantiatedFrom = ctorNode.resolvedSym;
	_checkedInstances.set(ctorSym, { sym: ctorSym, concreteTypes: types });

	// Re-check constructor body with concrete types in the class's DEFINING module ctx
	// (from _moduleCtxMap registry). This resolves private module-level symbols
	// referenced by the body — e.g. `let cap = INITIAL_CAPACITY;` in `HashSet.constructor`.
	// Fallback chain: registry → preludeCtx → caller's ctx. Reference parity: Nim's
	// `graph.ifaces[module]` lookup. Inject concrete type symbols so user types in type
	// args (e.g. Item in `new HashSet<Item>(...)`) are visible during resolveAnnotation.
	if (clonedBody != null) {
		const savedHost = bodyCtx.instantiatingCtx;
		bodyCtx.instantiatingCtx = host;
		const savedModulePath = bodyCtx.modulePath;
		bodyCtx.modulePath = classSym.modulePath != "" ? classSym.modulePath : ctx.modulePath;
		clearCheckerState(clonedBody);
		bindFunctionFlow(clonedBody, clonedBody);
		const callerScope = openInstanceScope(bodyCtx, params, types);
		bodyCtx.table.current.privateAccess = classSym;
		// Inject concrete type symbols (parity with instantiateGenericFunction).
		const injectedSyms: Symbol[] = [];
		for (const ct of types) {
			injectConcreteTypeSyms(ct, bodyCtx, ctx, injectedSyms);
		}
		const extPreCount = injectCallerExtensions(bodyCtx, ctx);
		// Replicate checkPass.ms:264-284: prepend `this` with concrete class type
		const ctorParams: string[] = ["this"];
		for (const p of fnParams) { ctorParams.push(p); }
		const outerGensym = beginGensymUnit();
		ctorDeclNode.paramSyms = callCheckFunctionBody(bodyCtx, ctorSym, ctorParams, clonedBody, null);
		rewindTemplateGensym(outerGensym);
		checkRoutineBorrows(bodyCtx, ctorDeclNode);
		bodyCtx.modulePath = savedModulePath;
		bodyCtx.instantiatingCtx = savedHost;
		removeInjectedSyms(bodyCtx, injectedSyms);
		bodyCtx.table.current = callerScope;
		truncateCallerExtensions(bodyCtx, extPreCount);
	}

	return ctorDeclNode;
}

// Register callback at module load time
registerInstantiateGeneric((sym: Symbol, params: Type[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation): Symbol => { return instantiateGenericFunction(sym, params, concreteTypes, ctx, callLoc); });
registerTypeInstanceHooks((instType: Type, ctx: CheckerContext, line: int32, col: int32): void => { instantiateHooksInType(instType, ctx, makeLoc(line, col), 0); });

test "an instantiation past the depth limit is an error naming the generic" {
	const ctx = createContext();
	ctx.genericInstDepth = 51;
	const sym = makeSymbol("nest", SymbolKind.Function, voidType(), false);
	const inst = instantiateGenericFunction(sym, [createGenericParam("T")], [voidType()], ctx, makeLoc(4, 17));
	assert inst == null;
	assert ctx.errors.length == 1;
	assert ctx.errors[0].message.indexOf("generic instantiation too nested: instantiating 'nest'") >= 0;
	assert ctx.errors[0].line == 4;
}

test "an instantiation at the depth limit is still attempted" {
	const ctx = createContext();
	ctx.genericInstDepth = 50;
	const sym = makeSymbol("nest", SymbolKind.Function, voidType(), false);
	instantiateGenericFunction(sym, [createGenericParam("T")], [voidType()], ctx, makeLoc(4, 17));
	assert ctx.errors.length == 0;
	assert ctx.genericInstDepth == 50;
}

function callerDeclaring(name: string, t: Type): CheckerContext {
	const ctx = createContext();
	const sym = makeSymbol(name, SymbolKind.Enum, t, false);
	sym.nameId = getIdentId(ctx.table.identCache, name);
	addSymbolToScope(ctx.table.current, sym);
	return ctx;
}

test "a struct type argument makes its enum field type visible in the instance body" {
	const color = createEnum("Color", ["Red", "Blue"], [0, 1]);
	const caller = callerDeclaring("Color", color);
	const body = createContext();
	assert lookupSymbol(body.table, "Color") == null;
	const injected: Symbol[] = [];
	injectConcreteTypeSyms(createStruct("Pixel", ["c", "x"], [color, int32Type()], true), body, caller, injected);
	assert lookupSymbol(body.table, "Color") != null;
	removeInjectedSyms(body, injected);
	assert lookupSymbol(body.table, "Color") == null;
}

test "a class type argument makes the enum of a member type one struct deeper visible" {
	const kind = createEnum("EvKind", ["Click", "Key"], [0, 1]);
	const caller = callerDeclaring("EvKind", kind);
	const body = createContext();
	const click = createStruct("ClickEv", ["kind", "x"], [createEnumLiteral(kind, "Click"), int32Type()], true);
	const injected: Symbol[] = [];
	injectConcreteTypeSyms(createRef(createStruct("Holder", ["ev"], [click], false)), body, caller, injected);
	assert lookupSymbol(body.table, "EvKind") != null;
	assert lookupSymbol(body.table, "ClickEv") != null;
}
