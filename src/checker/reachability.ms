// Global Dead Code Elimination — Reachability Analysis
//
// Computes an AliveSet of symbols by walking ASTs from roots (main, top-level
// stmts, test decls, exported symbols); symbol-less TypeInfo and hook
// declarations are still keyed "modulePath:name".

import { Node, NodeKind, NodeFlag, TypeKind, DeclKind, ProgramData, FunctionDeclData, HiddenStdConvData,
	ExportDeclData, VariableDeclData, ObjectLiteralData, ArrayLiteralData, ClassDeclData, ActorDeclData,
	CallExprData, MemberExprData, NewExprData, BinaryExprData, DecoratedDeclData, ExternDeclData, BlockStmtData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { getDeclName } from "./collectPass";
import {
	AliveSet,
	CTypeInfoDemand,
	createAliveSet,
	aliveSetAdd,
	aliveSetAddSym,
	aliveSetHasSym,
	aliveSetAddModule,
	aliveSetHas,
	aliveSetHasDecl,
	aliveSetHasModule,
	aliveSetModuleCount,
} from "../codegen/c/context";
import { ModuleGraph, findModule, createModuleGraph, createModule, addModule, createImportEntry } from "../module/graph";
import { hookBaseCName, hookBaseCNameOfSym, anonTypeName, isAnonTypeName, refArrayCellKey, refArrayCellOp, requireOpByKey, getOpByKey } from "../codegen/c/types";
import { hasFlag, SymbolFlag } from "./symbol";
import { hasGenericParams, isMaybeType, unwrapPointerLikeForVariant, unwrapRefNullUnion, awaitedType, createArray, createRef, hasAsgnFlag, getAttachedOp, peelTransparentInstance } from "./types";
import { SymbolKind, Symbol, Type, CallingConvention, AttachedOp } from "../ast/node";
import { monoInstanceName } from "../monomorphize/registry";
import { lookupCtorDefaults } from "./instantiate";
import { DispMethodEntry, dispatchEntryFor, dispatchOverridesFor } from "./context";

export function functionDeclIsAlive(aliveSet: Readonly<AliveSet>, modulePath: string, node: Readonly<Node>): boolean {
	if (aliveSet.entries.length == 0) return true;
	const name = (node.data as FunctionDeclData).fnName;
	const sym = node.resolvedSym;
	// $-prefixed functions without a traced routine symbol ($Env_*Destroy etc. DRC hooks) are
	// referenced by DRC-injected code the walker can't trace — keep them unconditionally alive.
	if (name.startsWith("$") && !isTracedRoutine(sym)) return true;
	return aliveSetHasDecl(aliveSet, modulePath, name, sym);
}

// ===== Global Name Index =====
// Pre-built name→modulePath index for O(1) cross-module lookup.
// Replaces the O(n*m) linear scan of all modules for unresolved identifiers.
// Built once at the start of computeAliveSet.
let _nameIndex: HashMap<string, string> = new HashMap<string, string>();

function nameIndexBuild(programs: Node[], paths: string[]): void {
	_nameIndex = new HashMap<string, string>();
	for (let m = 0; m < programs.length; m += 1) {
		const prog = programs[m];
		if (prog == null) continue;
		const pd = prog.data as ProgramData;
		const modPath = paths[m];
		for (const stmt of pd.programStmts) {
			if (stmt == null) continue;
			const name = getDeclName(stmt);
			if (name != "" && !_nameIndex.has(name)) {
				_nameIndex.set(name, modPath);
			}
		}
	}
}

function nameIndexLookup(name: string): string {
	const v = _nameIndex.get(name);
	if (v != null) return v;
	return "";
}

// ===== Declaration Index =====
// "modulePath:name" → its first top-level declaration; _declNext chains the
// overloads of one key in statement order. The first program of a path owns it.
let _declHead: HashMap<string, int32> = new HashMap<string, int32>();
let _declNodes: Node[] = [];
let _declNext: int32[] = [];
let _declPaths: string[] = [];
let _declWalked: boolean[] = [];
let _symDeclHead: HashMap<Symbol, int32> = new HashMap<Symbol, int32>();
let _symDeclNext: int32[] = [];
let _instDeclHead: HashMap<Symbol, int32> = new HashMap<Symbol, int32>();
let _instDeclNext: int32[] = [];

function declIndexBuild(programs: Node[], paths: string[]): void {
	_declHead = new HashMap<string, int32>();
	_declNodes = [];
	_declNext = [];
	_declPaths = [];
	_declWalked = [];
	_symDeclHead = new HashMap<Symbol, int32>();
	_symDeclNext = [];
	_instDeclHead = new HashMap<Symbol, int32>();
	_instDeclNext = [];
	const indexed = new HashSet<string>();
	for (let m = 0; m < programs.length; m += 1) {
		const modPath = paths[m];
		if (indexed.has(modPath)) continue;
		indexed.add(modPath);
		const prog = programs[m];
		if (prog == null) continue;
		const stmts = (prog.data as ProgramData).programStmts;
		for (let s = stmts.length - 1; s >= 0; s -= 1) {
			const decl = topDecl(stmts[s]);
			if (decl == null) continue;
			const key = modPath + ":" + topDeclName(decl);
			const next = _declHead.get(key) ?? -1;
			_declNodes.push(decl);
			_declNext.push(next);
			_declPaths.push(modPath);
			_declWalked.push(false);
			const at = _declNodes.length - 1;
			_declHead.set(key, at);
			const sym = decl.resolvedSym;
			_symDeclNext.push(sym != null ? (_symDeclHead.get(sym) ?? -1) : -1);
			if (sym != null) _symDeclHead.set(sym, at);
			const generic = sym != null ? sym.instantiatedFrom : null;
			_instDeclNext.push(generic != null ? (_instDeclHead.get(generic) ?? -1) : -1);
			if (generic != null) _instDeclHead.set(generic, at);
		}
	}
}

// ===== Visited Set (Set-based for O(1) lookup) =====

let _visitedSet: HashSet<string> = new HashSet<string>();
let _visitedSyms: HashSet<Symbol> = new HashSet<Symbol>();

function visitedHas(key: string): boolean {
	return _visitedSet.has(key);
}

function visitedAdd(key: string): void {
	_visitedSet.add(key);
}

// ===== Module-level state (avoids closure capture of value-type arrays/structs) =====

let _aliveSet: AliveSet = createAliveSet();
let _singleModule = "";

// ===== Core Walker =====

// Walk a node recursively, marking any referenced declarations alive.
function walkBody(node: Node, modulePath: string): void {
	if (node == null) return;
	if (node.nodeType != null) {
		let ut = node.nodeType;
		if ((ut.kind == TypeKind.Ref || ut.kind == TypeKind.Ptr) && ut.typeReturn != null) ut = ut.typeReturn;
		if (ut.kind == TypeKind.Union) {
			markUnionHookEdges(ut);
		}
	}
	const k = node.kind;

	// Identifier — mark its declaration alive
	if (k == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym != null && hasFlag(sym, SymbolFlag.GeneratedOp) && sym.modulePath == "") {
			noteOpUse(sym, modulePath);
			markAndWalk(modulePath, sym.name);
			const hookMod = nameIndexLookup(sym.name);
			if (hookMod != "" && hookMod != modulePath) {
				markAndWalk(hookMod, sym.name);
			}
			return;
		}
		if (sym != null) markReferenced(sym, modulePath);
		return;
	}

	// CallExpr — walk callee and arguments
	if (k == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		const magic = cd.callee.resolvedSym != null ? cd.callee.resolvedSym.builtinKind : "";
		if (magic == "BoxRefArray" && cd.arguments.length > 0 && cd.arguments[0].nodeType != null) {
			markRefArrayCell(cd.arguments[0].nodeType, modulePath);
		} else if (magic == "PromiseAllFor" && node.nodeType != null) {
			markPromiseAllResult(node.nodeType, modulePath);
		}
		walkBody(cd.callee, modulePath);
		for (const arg of cd.arguments) {
			walkBody(arg, modulePath);
		}
		return;
	}

	if (k == NodeKind.NewExpr) {
		const nd = node.data as NewExprData;
		walkBody(nd.newCallee, modulePath);
		for (const arg of nd.newArguments) {
			walkBody(arg, modulePath);
		}
		markTypeInfoEdge(node, modulePath);
		return;
	}

	// ObjectLiteral — allocation site: the emitted C references <T>TypeInfo,
	// whose initializer references <T>Destroy/<T>Trace (TypeInfo→hook edge).
	if (k == NodeKind.ObjectLiteral) {
		markTypeInfoEdge(node, modulePath);
		walkChildrenGeneric(node, modulePath);
		return;
	}

	if (k == NodeKind.VariableDecl && node.nodeType != null && node.nodeType.kind == TypeKind.Ref
			&& node.nodeType.typeReturn != null && node.nodeType.typeReturn.kind == TypeKind.Array
			&& isBakeableAggregateConst(node)) {
		markRefArrayCell(node.nodeType.typeReturn, modulePath);
	}

	if (k == NodeKind.HiddenSubConv && node.variantSlot > 0) {
		markRematerializedMemberTypeInfo((node.data as HiddenStdConvData).convType, modulePath);
		walkChildrenGeneric(node, modulePath);
		return;
	}

	if (k == NodeKind.TypeAssertion && node.flags.has(NodeFlag.ObjCheck)) {
		markTypeInfoEdge(node, modulePath);
		walkChildrenGeneric(node, modulePath);
		return;
	}

	if (k == NodeKind.BinaryExpr && (node.data as BinaryExprData).operator == "instanceof") {
		const rhs = (node.data as BinaryExprData).right;
		markTypeInfoOf(rhs.resolvedSym != null ? rhs.resolvedSym.symbolType : rhs.nodeType, modulePath);
		walkChildrenGeneric(node, modulePath);
		return;
	}

	// MemberExpr — walk object + mark resolved extension/class method
	if (k == NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		walkBody(md.object, modulePath);
		if (node.resolvedSym != null) markReferenced(node.resolvedSym, modulePath);
		return;
	}

	// For all other nodes: walk children generically via forEachChild
	// NOTE: forEachChild uses a callback — we pass module-level state
	// instead of closure-captured value-type arrays to avoid use-after-free
	walkChildrenGeneric(node, modulePath);
}

function markRefArrayCell(arrT: Type, modulePath: string): void {
	const key = refArrayCellKey(arrT);
	if (_aliveSet.typeInfoKeys.has(key)) return;
	const destroy = refArrayCellOp(arrT, AttachedOp.AttachedDestructor);
	if (destroy == null) throw new Error(`internal: ref-array cell ${key} is boxed in ${modulePath} before its destroy op was lifted`);
	const trace = refArrayCellOp(arrT, AttachedOp.AttachedTrace);
	let owner = _singleModule != "" ? _singleModule : modulePath;
	if (_singleModule == "") {
		if (destroy.modulePath != "") owner = destroy.modulePath;
		if (trace != null) {
			if (destroy.modulePath != "" && destroy.modulePath != trace.modulePath) {
				throw new Error(`internal: ref-array cell ${key} has its destroy op in ${destroy.modulePath} and its trace op in ${trace.modulePath}`);
			}
			owner = trace.modulePath;
		}
	}
	_aliveSet.typeInfoKeys.add(key);
	const demand: CTypeInfoDemand = { cell: createRef(arrT), key, owner, cName: "", destroy, trace };
	_aliveSet.typeInfos.push(demand);
	aliveSetAddModule(_aliveSet, owner);
	markReferenced(destroy, owner);
	if (trace != null) markReferenced(trace, owner);
}

function markPromiseAllResult(resultType: Type, modulePath: string): void {
	let collected = awaitedType(resultType);
	if (collected != null && collected.kind == TypeKind.Ref && collected.typeReturn != null) collected = collected.typeReturn;
	if (collected == null || collected.kind != TypeKind.Array || collected.typeReturn == null) return;
	const elem = collected.typeReturn;
	if (elem.kind != TypeKind.Struct || elem.typeName == "" || !hasAsgnFlag(elem)) return;
	markReferenced(requireOpByKey(createArray(elem), AttachedOp.AttachedDestructor), modulePath);
}

// Union narrow/project sites make codegen emit variant Copy/Destroy calls by
// name with no AST edge — any walked node typed Union pins its variants' hooks.
function markUnionHookEdges(t: Type): void {
	for (const vt of t.typeChildren) {
		if (vt == null) continue;
		let vbase = vt;
		if ((vt.kind == TypeKind.Ref || vt.kind == TypeKind.Ptr) && vt.typeReturn != null) vbase = vt.typeReturn;
		const vn = hookBaseCName(vbase.typeName, vbase, null);
		if (vn.length == 0) continue;
		for (const hn of [vn + "Copy", vn + "Destroy", vn + "Trace"]) {
			const h = nameIndexLookup(hn);
			if (h != "") {
				markAndWalk(h, hn);
			}
		}
	}
	if (t.typeName.length > 0) {
		const un = hookBaseCName(t.typeName, t, null);
		for (const uhn of [un + "Copy", un + "Sink", un + "WasMoved"]) {
			const uh = nameIndexLookup(uhn);
			if (uh != "") {
				markAndWalk(uh, uhn);
			}
		}
	}
}

// Allocation site → <T>TypeInfo edge. The emitted allocation references the
// type's TypeInfo global, whose initializer references <T>Destroy/<T>Trace —
// the only AST path to ref-type hooks (msDecref dispatches through TypeInfo
// at runtime, so no direct call site exists). Mirrors codegen's on-demand
// TypeInfo emission: mark only when the TypeInfo decl really exists.
function markTypeInfoEdge(node: Node, modulePath: string): void {
	markTypeInfoOf(node.nodeType, modulePath);
}

function markTypeInfoHooks(t: Type, modulePath: string): void {
	const destroy = getOpByKey(t, AttachedOp.AttachedDestructor) ?? getAttachedOp(t, AttachedOp.AttachedDestructor);
	if (destroy != null) markReferenced(destroy, modulePath);
	const trace = getOpByKey(t, AttachedOp.AttachedTrace) ?? getAttachedOp(t, AttachedOp.AttachedTrace);
	if (trace != null) markReferenced(trace, modulePath);
}

function markRematerializedMemberTypeInfo(conv: Type | null, modulePath: string): void {
	if (conv == null || conv.kind == TypeKind.Union) return;
	const member = unwrapPointerLikeForVariant(conv);
	if (member != null && member != conv && member.kind == TypeKind.Struct) markTypeInfoOf(member, modulePath);
}

function markTypeInfoOf(type: Type | null, modulePath: string): void {
	if (type == null) return;
	let t = peelTransparentInstance(type);
	const nullableRef = unwrapRefNullUnion(t);
	if (nullableRef != null) t = nullableRef;
	if (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) {
		if (t.typeReturn != null) {
			t = t.typeReturn;
		} else if (t.typeChildren.length > 0 && t.typeChildren[0] != null) {
			t = t.typeChildren[0];
		} else {
			return;
		}
	}
	if (t.kind != TypeKind.Struct && t.kind != TypeKind.TypeReference && t.kind != TypeKind.GenericInstance && t.kind != TypeKind.Union) return;
	if (t.kind == TypeKind.GenericInstance && t.typeName != "" && t.typeChildren.length > 0) {
		const mono = monoInstanceName(t);
		for (const hn of [mono + "TypeInfo", mono + "Destroy", mono + "Trace"]) {
			const h = nameIndexLookup(hn);
			if (h != "") {
				markAndWalk(h, hn);
			}
		}
	}
	if (t.kind == TypeKind.Union) {
		markUnionHookEdges(t);
	}
	if (t.kind == TypeKind.Struct && (isAnonTypeName(t.typeName) || t.typeName.startsWith("__anon")) && t.typeNames.length > 0) {
		const an = isAnonTypeName(t.typeName) ? anonTypeName(t) : t.typeName;
		for (const hn of [an + "Destroy", an + "Trace"]) {
			const h = nameIndexLookup(hn);
			if (h != "") {
				markAndWalk(h, hn);
			}
		}
		return;
	}
	const tn = t.typeName;
	if (tn.length == 0) return;
	const tiName = tn + "TypeInfo";
	// The name index maps a name to ONE home, so a type name declared by several
	// modules resolves to an arbitrary one; the type's own symbol is the identity
	// that says which module's TypeInfo this allocation demands.
	if (t.sym != null && t.sym.modulePath != "") {
		markAndWalk(t.sym.modulePath, tiName);
	}
	const home = nameIndexLookup(tiName);
	if (home != "") {
		markAndWalk(home, tiName);
	}
	if (t.kind != TypeKind.Struct) return;
	markTypeInfoHooks(t, t.sym != null && t.sym.modulePath != "" ? t.sym.modulePath : (home != "" ? home : modulePath));
	let bt = t.typeExtra;
	let depth = 0;
	while (bt != null && depth < 64) {
		let inner = bt;
		if (inner.kind == TypeKind.Ref && inner.typeReturn != null) inner = inner.typeReturn;
		if (inner.kind != TypeKind.Struct || inner.typeName == "") break;
		const btiName = inner.typeName + "TypeInfo";
		if (inner.sym != null && inner.sym.modulePath != "") {
			markAndWalk(inner.sym.modulePath, btiName);
		}
		const bHome = nameIndexLookup(btiName);
		if (bHome != "") {
			markAndWalk(bHome, btiName);
		}
		bt = inner.typeExtra;
		depth += 1;
	}
}

// Walk all children of a node generically via shared forEachChild
function walkChildrenGeneric(node: Node, modulePath: string): void {
	forEachChild(node, (child: Node): void => {
		walkBody(child, modulePath);
	});
}

// Mark a symbol alive and walk its body if not already visited.
// Walks ALL overloads with the same name (not just the first).
function markAndWalk(modulePath: string, name: string): void {
	const key = modulePath + ":" + name;
	if (visitedHas(key)) return;
	visitedAdd(key);
	aliveSetAdd(_aliveSet, modulePath, name);

	// Walk ALL declarations with this name (handles overloaded functions)
	let di = _declHead.get(key) ?? -1;
	while (di >= 0) {
		walkDecl(di);
		di = _declNext[di];
	}
}

// Dispatch bucket edge (Nim cgmeth: a reachable base method makes every
// override + its class TypeInfo reachable — the msDisp_* if-chain
// references them all regardless of static call sites).
function markDispatchOverrides(dde: DispMethodEntry | null): void {
	if (dde == null || dde.overloaded) return;
	for (const ov of dispatchOverridesFor(dde.classSym, dde.methodName)) {
		markSymAndWalk(ov.sym, ov.sym.modulePath);
		markAndWalk(ov.classSym.modulePath, ov.classSym.name + "TypeInfo");
	}
}

function opHome(sym: Symbol, user: string): string {
	if (sym.modulePath != "") return sym.modulePath;
	let home = "";
	let di = _symDeclHead.get(sym) ?? -1;
	while (di >= 0) {
		if (_declPaths[di] == user) return user;
		if (home == "") home = _declPaths[di];
		di = _symDeclNext[di];
	}
	return home;
}

function noteOpUse(sym: Symbol, user: string): void {
	if (!hasFlag(sym, SymbolFlag.GeneratedOp)) return;
	const home = opHome(sym, user);
	if (home == "" || home == user) return;
	const users = _aliveSet.foreignOps.get(sym);
	if (users == null) _aliveSet.foreignOps.set(sym, [user]);
	else if (!users.includes(user)) users.push(user);
}

function markReferenced(sym: Symbol, modulePath: string): void {
	noteOpUse(sym, modulePath);
	markSymAndWalk(sym, modulePath);
	for (const overload of sym.overloads) markSymAndWalk(overload, modulePath);
}

function markSymAndWalk(sym: Symbol, modulePath: string): void {
	if (_visitedSyms.has(sym)) return;
	_visitedSyms.add(sym);
	aliveSetAddSym(_aliveSet, sym);
	const home = sym.modulePath != "" ? sym.modulePath : modulePath;
	aliveSetAddModule(_aliveSet, home);
	markDispatchOverrides(dispatchEntryFor(sym));
	let di = _symDeclHead.get(sym) ?? -1;
	if (di < 0 && sym.instantiatedFrom != null) {
		markInstanceCopy(sym.instantiatedFrom, sym.name);
		return;
	}
	while (di >= 0) {
		walkDecl(di);
		di = _symDeclNext[di];
	}
}

function markInstanceCopy(generic: Symbol, name: string): void {
	let di = _instDeclHead.get(generic) ?? -1;
	while (di >= 0) {
		if (_declNodes[di].resolvedSym.name == name) walkDecl(di);
		di = _instDeclNext[di];
	}
}

function markClassInit(classDecl: Node, modulePath: string, className: string): void {
	const entry = classDecl.resolvedSym != null ? lookupCtorDefaults(classDecl.resolvedSym, className) : null;
	if (entry != null && entry.initSym != null) markSymAndWalk(entry.initSym, modulePath);
}

function markRootDecl(decl: Node, modulePath: string): void {
	if (decl.resolvedSym != null) markSymAndWalk(decl.resolvedSym, modulePath);
	else markAndWalk(modulePath, topDeclName(decl));
}

function walkDecl(di: int32): void {
	if (_declWalked[di]) return;
	_declWalked[di] = true;
	const found = _declNodes[di];
	const modulePath = _declPaths[di];
	const name = topDeclName(found);
	if (found.resolvedSym != null) {
		aliveSetAddSym(_aliveSet, found.resolvedSym);
		markDispatchOverrides(dispatchEntryFor(found.resolvedSym));
	} else {
		aliveSetAdd(_aliveSet, modulePath, name);
	}
	aliveSetAddModule(_aliveSet, modulePath);
	if (found.nodeType != null && hasGenericParams(found.nodeType)) return;
	walkBody(found, modulePath);
	// Codegen lowers `super(args)` to `<Parent>_init(this, args)` with no AST
	// edge, so a live class keeps its init alive, as `new C(...)` needs.
	if (found.kind == NodeKind.ClassDecl) markClassInit(found, modulePath, name);
	// Actors: actorLower erased the NewExpr before this walk runs, so
	// no allocation-site edge fires — but a spawned actor's TypeInfo
	// is always demanded.
	const isActorOrigin = found.kind == NodeKind.ActorDecl
		|| (found.kind == NodeKind.ClassDecl && found.resolvedSym != null
			&& found.resolvedSym.symbolKind == SymbolKind.Actor);
	if (isActorOrigin) {
		const acName = hookBaseCNameOfSym(name, found.resolvedSym);
		markAndWalk(modulePath, name + "TypeInfo");
		markAndWalk(modulePath, acName + "Destroy");
		markAndWalk(modulePath, acName + "Trace");
	}
}

// The declaration a top-level statement introduces, unwrapped from
// ExportDecl/DecoratedDecl, or null when it declares nothing walkable.
function topDecl(node: Node | null): Node | null {
	if (node == null) return null;
	const k = node.kind;
	if (k == NodeKind.ExportDecl) return topDecl((node.data as ExportDeclData).exportedDecl);
	if (k == NodeKind.DecoratedDecl) return topDecl((node.data as DecoratedDeclData).decoratedNode);
	if (k == NodeKind.FunctionDecl || k == NodeKind.VariableDecl || k == NodeKind.ClassDecl
		|| k == NodeKind.ActorDecl || k == NodeKind.InterfaceDecl || k == NodeKind.StructDecl
		|| k == NodeKind.EnumDecl || k == NodeKind.TypeAliasDecl || k == NodeKind.ExternDecl) return node;
	return null;
}

function topDeclName(decl: Node): string {
	const k = decl.kind;
	if (k == NodeKind.FunctionDecl) return (decl.data as FunctionDeclData).fnName;
	if (k == NodeKind.VariableDecl) return (decl.data as VariableDeclData).declName;
	if (k == NodeKind.ClassDecl) return (decl.data as ClassDeclData).className;
	if (k == NodeKind.ActorDecl) return (decl.data as ActorDeclData).actorName;
	if (k == NodeKind.InterfaceDecl || k == NodeKind.StructDecl) {
		return (decl.data as { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[] }).interfaceName;
	}
	if (k == NodeKind.EnumDecl) return (decl.data as { enumName: string, enumMembers: string[] }).enumName;
	if (k == NodeKind.TypeAliasDecl) return (decl.data as { aliasName: string, aliasType: string, aliasIsDistinct: boolean }).aliasName;
	return (decl.data as ExternDeclData).externName;
}

const ANY_EXPORT = "*";

function declaredNameAlive(modulePath: string, name: string): boolean {
	if (aliveSetHas(_aliveSet, modulePath, name)) return true;
	let di = _declHead.get(modulePath + ":" + name) ?? -1;
	while (di >= 0) {
		const sym = _declNodes[di].resolvedSym;
		if (sym != null && aliveSetHasSym(_aliveSet, sym)) return true;
		di = _declNext[di];
	}
	return false;
}

function reachesAliveThroughReexports(graph: ModuleGraph, modulePath: string, name: string, memo: HashMap<string, boolean>): boolean {
	const anyName = name == ANY_EXPORT;
	if (anyName ? aliveSetHasModule(_aliveSet, modulePath) : declaredNameAlive(modulePath, name)) return true;
	const key = modulePath + ":" + name;
	const known = memo.get(key);
	if (known != null) return known;
	memo.set(key, false);
	const mod = findModule(graph, modulePath);
	if (mod == null) return false;
	let reached = false;
	for (const imp of mod.imports) {
		for (let i = 0; i < imp.names.length; i += 1) {
			const isStar = imp.names[i] == ANY_EXPORT;
			const isNamespaceImport = isStar && imp.aliases[i] != ANY_EXPORT;
			if (isNamespaceImport) continue;
			let sourceName = "";
			if (isStar) {
				sourceName = name;
			} else if (anyName || imp.aliases[i] == name) {
				sourceName = imp.names[i];
			}
			if (sourceName == "") continue;
			if (reachesAliveThroughReexports(graph, imp.sourcePath, sourceName, memo)) reached = true;
		}
	}
	if (reached) {
		memo.set(key, true);
		aliveSetAddModule(_aliveSet, modulePath);
	}
	return reached;
}

function markReexportConduitsAlive(graph: ModuleGraph): void {
	const memo = new HashMap<string, boolean>();
	for (const mod of graph.modules) {
		if (!aliveSetHasModule(_aliveSet, mod.path)) continue;
		for (const imp of mod.imports) {
			for (let i = 0; i < imp.names.length; i += 1) {
				const isStarExport = imp.names[i] == ANY_EXPORT && imp.aliases[i] == ANY_EXPORT;
				if (isStarExport) continue;
				reachesAliveThroughReexports(graph, imp.sourcePath, imp.names[i], memo);
			}
		}
	}
}

function markSideEffectImportsAlive(graph: ModuleGraph): void {
	const pending: string[] = [];
	for (const mod of graph.modules) {
		if (aliveSetHasModule(_aliveSet, mod.path)) pending.push(mod.path);
	}
	while (pending.length > 0) {
		const mod = findModule(graph, pending.pop());
		if (mod == null) continue;
		for (const imp of mod.imports) {
			if (imp.names.length > 0 || aliveSetHasModule(_aliveSet, imp.sourcePath)) continue;
			aliveSetAddModule(_aliveSet, imp.sourcePath);
			pending.push(imp.sourcePath);
		}
	}
}

function markImportedModulesAlive(graph: ModuleGraph): void {
	let known: int32 = -1;
	while (aliveSetModuleCount(_aliveSet) != known) {
		known = aliveSetModuleCount(_aliveSet);
		markSideEffectImportsAlive(graph);
		markReexportConduitsAlive(graph);
	}
}

// ===== Public API =====

export function computeAliveSet(
	programs: Node[],
	paths: string[],
	entryPath: string,
	isTest: boolean,
	graph: ModuleGraph,
	exportRootModules: string[] = [],
	exportRootFunctions: Symbol[] = [],
): AliveSet {
	const rootFunctions = new HashSet<Symbol>();
	for (const sym of exportRootFunctions) {
		rootFunctions.add(sym);
		for (const overload of sym.overloads) rootFunctions.add(overload);
	}
	_aliveSet = createAliveSet();
	_visitedSet = new HashSet<string>();
	_visitedSyms = new HashSet<Symbol>();
	nameIndexBuild(programs, paths);
	declIndexBuild(programs, paths);
	aliveSetAddModule(_aliveSet, entryPath);
	const globalDestroys: GlobalDestroysBlock[] = [];

	// For each module, find roots and mark them alive
	for (let m = 0; m < programs.length; m += 1) {
		const modulePath = paths[m];
		const program = programs[m];
		if (program == null) continue;
		const d = program.data as ProgramData;

		for (const stmt of d.programStmts) {
			if (stmt == null) continue;

			// Unwrap DecoratedDecl (module-level @passC/@passL/... wrap the next
			// decl) so name/kind roots below see the real decl — topDecl
			// already unwraps; the root scan must too or a decorated `main` is
			// invisible and the whole entry module goes dead.
			let bare = stmt;
			if (bare.kind == NodeKind.DecoratedDecl) {
				const ddw = bare.data as DecoratedDeclData;
				if (ddw.decoratedNode != null) bare = ddw.decoratedNode;
			}

			// Root 1: main() in entry module
			if (modulePath == entryPath && bare.kind == NodeKind.FunctionDecl) {
				const fd = bare.data as FunctionDeclData;
				if (fd.fnName == "main") {
					markRootDecl(bare, modulePath);
					continue;
				}
			}
			// Also check exported main under ExportDecl
			if (modulePath == entryPath && bare.kind == NodeKind.ExportDecl) {
				const ed = bare.data as ExportDeclData;
				if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.FunctionDecl) {
					const fd = ed.exportedDecl.data as FunctionDeclData;
					if (fd.fnName == "main") {
						markRootDecl(ed.exportedDecl, modulePath);
						continue;
					}
				}
			}

			// Root 2: Compiler-generated functions — always alive.
			// Must match functionDeclIsAlive exemptions above exactly:
			// $prefix without a traced routine symbol (DRC hooks), =prefix (operators),
			// __prefix (builtinLower), DRC lifecycle suffixes, generic instantiations (__ in middle of name).
			if (bare.kind == NodeKind.FunctionDecl) {
				const fd2 = bare.data as FunctionDeclData;
				const fn = fd2.fnName;
				if (fn.length > 0 && fn.slice(0, 1) == "$" && !isTracedRoutine(bare.resolvedSym)) {
					walkBody(bare, modulePath);
					continue;
				}
				if (bare.resolvedSym != null && rootFunctions.has(bare.resolvedSym)) {
					markSymAndWalk(bare.resolvedSym, modulePath);
					continue;
				}
			}

			// Root 3: TestDecl nodes — in test mode (all modules) or entry module (build mode).
			// Entry module test blocks are wrapped in main() by codegen, so they're always roots.
			if (bare.kind == NodeKind.TestDecl && (isTest || modulePath == entryPath)) {
				walkBody(bare, modulePath);
				continue;
			}

			// Root 4: Top-level statements (side-effecting init code in Init000).
			// Unwrap ExportDecl — `export const argv = buildArgv()` is an ExportDecl
			// wrapping a VariableDecl. The inner VariableDecl is side-effecting (init code).
			let initStmt = bare;
			if (bare.kind == NodeKind.ExportDecl) {
				const ed = bare.data as ExportDeclData;
				if (ed.exportedDecl != null) initStmt = ed.exportedDecl;
			}
			if (bare.kind == NodeKind.BlockStmt && bare.flags.has(NodeFlag.GlobalDestroys)) {
				const walked: boolean[] = [];
				for (let i = 0; i < (bare.data as BlockStmtData).statements.length; i += 1) walked.push(false);
				globalDestroys.push({ modulePath, block: bare, walked });
				continue;
			}
			if (isTopLevelStatement(initStmt)) {
				walkBody(bare, modulePath);
				continue;
			}

			if (exportsCSymbol(bare)) {
				markRootDecl(topDecl(bare)!, modulePath);
				continue;
			}

			if ((modulePath == entryPath || exportRootModules.includes(modulePath)) && isExportedDecl(bare)) {
				const decl = topDecl(bare);
				if (decl != null) {
					markRootDecl(decl, modulePath);
				} else {
					const name = getDeclName(bare);
					if (name != "") markAndWalk(modulePath, name);
				}
			}
		}
	}

	markImportedModulesAlive(graph);
	while (markAliveGlobalDestroys(globalDestroys)) markImportedModulesAlive(graph);
	return takeReachability();
}

interface GlobalDestroysBlock {
	modulePath: string;
	block: Node;
	walked: boolean[];
}

// A module's global destroys are no root: each global's destroy is alive exactly when the
// global is, so a module that is otherwise dead stays dead.
function markAliveGlobalDestroys(pending: GlobalDestroysBlock[]): boolean {
	let walked = false;
	for (const entry of pending) {
		const destroys = (entry.block.data as BlockStmtData).statements;
		for (let i = 0; i < destroys.length; i += 1) {
			if (entry.walked[i]) continue;
			const one = destroys[i];
			const owner = one.resolvedSym;
			if (owner != null ? !aliveSetHasSym(_aliveSet, owner) : !aliveSetHasModule(_aliveSet, entry.modulePath)) continue;
			entry.walked[i] = true;
			walkBody(one, entry.modulePath);
			walked = true;
		}
	}
	return walked;
}

function takeReachability(): AliveSet {
	const result = _aliveSet;
	_aliveSet = createAliveSet();
	_singleModule = "";
	_visitedSet = new HashSet<string>();
	_visitedSyms = new HashSet<Symbol>();
	_nameIndex = new HashMap<string, string>();
	_declHead = new HashMap<string, int32>();
	_declNodes = [];
	_declNext = [];
	_declPaths = [];
	_declWalked = [];
	_symDeclHead = new HashMap<Symbol, int32>();
	_symDeclNext = [];
	_instDeclHead = new HashMap<Symbol, int32>();
	_instDeclNext = [];
	return result;
}

export function collectModuleTypeInfoDemands(program: Node, modulePath: string): AliveSet {
	_aliveSet = createAliveSet();
	_visitedSet = new HashSet<string>();
	_visitedSyms = new HashSet<Symbol>();
	_singleModule = modulePath;
	nameIndexBuild([program], [modulePath]);
	declIndexBuild([program], [modulePath]);
	for (const stmt of (program.data as ProgramData).programStmts) {
		const decl = topDecl(stmt);
		if (decl != null && decl.nodeType != null && hasGenericParams(decl.nodeType)) continue;
		walkBody(stmt, modulePath);
	}
	const walked = takeReachability();
	const demands = createAliveSet();
	demands.typeInfos = walked.typeInfos;
	demands.typeInfoKeys = walked.typeInfoKeys;
	return demands;
}

// Check if a statement is a side-effecting top-level statement (not a declaration)
function isTopLevelStatement(node: Node): boolean {
	const k = node.kind;
	if (k == NodeKind.ExprStmt) return true;
	if (k == NodeKind.IfStmt) return true;
	if (k == NodeKind.WhileStmt) return true;
	if (k == NodeKind.ForStmt) return true;
	if (k == NodeKind.ForOfStmt) return true;
	if (k == NodeKind.TryCatchStmt) return true;
	if (k == NodeKind.ThrowStmt) return true;
	if (k == NodeKind.BlockStmt) return true;
	if (k == NodeKind.AssertStmt) return true;
	if (k == NodeKind.VariableDecl) return varDeclNeedsRuntimeInit(node);
	return false;
}

function varDeclNeedsRuntimeInit(node: Node): boolean {
	const d = node.data as VariableDeclData;
	if (d.initializer == null) return false;
	const n = d.declName;
	if (n.length > 8 && n.slice(n.length - 8, n.length) == "TypeInfo") return false;
	const k = d.initializer.kind;
	if (k == NodeKind.NumberLiteral) return false;
	if (k == NodeKind.BooleanLiteral) return false;
	if (k == NodeKind.StringLiteral) {
		return !(node.nodeType != null && node.nodeType.kind == TypeKind.String);
	}
	if (k == NodeKind.NullLiteral) return false;
	if (k == NodeKind.ObjectLiteral) return !isBakeableAggregateConst(node);
	if (k == NodeKind.ArrayLiteral || k == NodeKind.CallExpr) return !isBakeableAggregateConst(node);
	return true;
}

// Empty array only: a non-empty bake would place the element buffer in static
// memory, and any later push/realloc on that buffer is UB. Empty = { len 0,
// p NULL }, a state the runtime already grows from (msArrayPrepareAdd).
// nativeLower wraps top-level array initializers in msBoxRefArray(lit) before
// computeAliveSet runs, so the literal is peeled out of that call here.
function bakeableEmptyArrayLiteral(init: Readonly<Node>): boolean {
	if (init.kind == NodeKind.ArrayLiteral) {
		const ad = init.data as ArrayLiteralData;
		return ad.elements.length == 0;
	}
	if (init.kind != NodeKind.CallExpr) return false;
	const cd = init.data as CallExprData;
	if (init.resolvedSym == null || init.resolvedSym.builtinKind != "BoxRefArray") return false;
	if (cd.arguments.length != 1) return false;
	return bakeableEmptyArrayLiteral(cd.arguments[0]);
}

// A routine reached only through its references; a DRC hook's references are injected later.
export function isTracedRoutine(sym: Symbol | null): boolean {
	return sym != null && sym.symbolKind == SymbolKind.Function && !hasFlag(sym, SymbolFlag.GeneratedOp);
}

export function isClosureThunkConv(node: Readonly<Node>): boolean {
	if (node.kind != NodeKind.HiddenStdConv) return false;
	const cv = node.data as HiddenStdConvData;
	return cv.convType.kind == TypeKind.Function && cv.convType.callConv == CallingConvention.CcClosure
		&& cv.convExpr.nodeType != null && cv.convExpr.nodeType.kind == TypeKind.Function
		&& cv.convExpr.nodeType.callConv != CallingConvention.CcClosure;
}

export function isBakeableAggregateConst(node: Readonly<Node>): boolean {
	const d = node.data as VariableDeclData;
	if (d.declKind != DeclKind.Const) return false;
	if (d.initializer == null) return false;
	const init = d.initializer;
	if (init.kind == NodeKind.ArrayLiteral || init.kind == NodeKind.CallExpr) {
		return bakeableEmptyArrayLiteral(init);
	}
	if (init.kind == NodeKind.HiddenStdConv) {
		const cv = init.data as HiddenStdConvData;
		if (!isMaybeType(cv.convType)) return false;
		return match (cv.convExpr.kind) {
			NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral => true,
			NodeKind.HiddenStdConv => isClosureThunkConv(cv.convExpr),
			_ => false,
		};
	}
	if (init.kind != NodeKind.ObjectLiteral) return false;
	if (init.flags.has(NodeFlag.Closure)) return false;
	const od = init.data as ObjectLiteralData;
	if (od.properties.length == 0) return false;
	for (const prop of od.properties) {
		if (prop == null) return false;
		const bakeable = match (prop.kind) {
			NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral => true,
			NodeKind.ObjectLiteral => prop.flags.has(NodeFlag.Closure),
			_ => false,
		};
		if (!bakeable) return false;
	}
	return true;
}

function isExportedDecl(node: Node): boolean {
	if (node.kind == NodeKind.ExportDecl) return true;
	// DecoratedDecl wrapping an ExportDecl
	if (node.kind == NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return isExportedDecl(d.decoratedNode);
	}
	return false;
}

function exportsCSymbol(node: Node): boolean {
	let decl = node;
	if (decl.kind == NodeKind.ExportDecl) {
		const ed = decl.data as ExportDeclData;
		if (ed.exportedDecl == null) return false;
		decl = ed.exportedDecl;
	}
	if (decl.kind != NodeKind.FunctionDecl) return false;
	const sym = decl.resolvedSym;
	return sym != null && sym.exportName != "";
}

// getDeclName imported from collectPass (single canonical copy)

// ===== Tests =====

test "endsWith helper" {
	assert "foo/bar.ms".endsWith("bar.ms");
	assert "foo/bar.ms".endsWith("foo/bar.ms");
	assert !"foo/bar.ms".endsWith("baz.ms");
}

test "empty programs produce empty alive set" {
	const aliveSet = computeAliveSet([], [], "/entry.ms", false, createModuleGraph());
	assert aliveSet.entries.length == 0;
}

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { createStruct, createRef, createUnion, nullType, stringType } from "./types";
import { aliveSetHas } from "../codegen/c/context";

test "nullable reference allocation keeps its concrete TypeInfo alive" {
	const parsed = parseSource("const HolderTypeInfo = 0; let value = { label: \"held\" };");
	assert parsed.ok;
	if (!parsed.ok) return;
	const stmts = (parsed.value.data as ProgramData).programStmts;
	const allocation = (stmts[1].data as VariableDeclData).initializer;
	assert allocation != null;
	if (allocation == null) return;
	const body = createStruct("Holder", ["label"], [stringType()], true);
	allocation.nodeType = createUnion([createRef(body), nullType()]);
	const alive = computeAliveSet([parsed.value], ["owner.ms"], "owner.ms", false, createModuleGraph());
	assert aliveSetHas(alive, "owner.ms", "HolderTypeInfo");
}

function importGraph(edges: string[][]): ModuleGraph {
	const graph = createModuleGraph();
	for (const e of edges) {
		let mod = findModule(graph, e[0]);
		if (mod == null) {
			mod = createModule(e[0]);
			addModule(graph, mod);
		}
		if (e.length == 2) mod.imports.push(createImportEntry([], [], e[1], e[1]));
		if (e.length == 4) mod.imports.push(createImportEntry([e[1]], [e[2]], e[3], e[3]));
	}
	return graph;
}

function moduleAlive(graph: ModuleGraph, modulePath: string): boolean {
	_aliveSet = createAliveSet();
	aliveSetAdd(_aliveSet, "/main.ms", "main");
	aliveSetAdd(_aliveSet, "/impl.ms", "add");
	markImportedModulesAlive(graph);
	const alive = aliveSetHasModule(_aliveSet, modulePath);
	_aliveSet = createAliveSet();
	return alive;
}

test "named re-export on the path to an alive symbol keeps its module alive" {
	const graph = importGraph([["/main.ms", "add", "add", "/hub.ms"], ["/hub.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert moduleAlive(graph, "/hub.ms");
}

test "aliased re-export resolves the source name" {
	const graph = importGraph([["/main.ms", "plus", "plus", "/hub.ms"], ["/hub.ms", "add", "plus", "/impl.ms"], ["/impl.ms"]]);
	assert moduleAlive(graph, "/hub.ms");
}

test "star re-export on the path to an alive symbol keeps its module alive" {
	const graph = importGraph([["/main.ms", "add", "add", "/hub.ms"], ["/hub.ms", "*", "*", "/impl.ms"], ["/impl.ms"]]);
	assert moduleAlive(graph, "/hub.ms");
}

test "every module of a re-export chain stays alive" {
	const graph = importGraph([["/main.ms", "add", "add", "/outer.ms"], ["/outer.ms", "add", "add", "/inner.ms"], ["/inner.ms", "*", "*", "/impl.ms"], ["/impl.ms"]]);
	assert moduleAlive(graph, "/outer.ms");
	assert moduleAlive(graph, "/inner.ms");
}

test "two hubs sharing one inner hub both stay alive" {
	const graph = importGraph([["/main.ms", "add", "add", "/hubA.ms"], ["/main.ms", "add", "add2", "/hubB.ms"],
		["/hubA.ms", "add", "add", "/inner.ms"], ["/hubB.ms", "add", "add", "/inner.ms"], ["/inner.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert moduleAlive(graph, "/hubA.ms");
	assert moduleAlive(graph, "/hubB.ms");
}

test "namespace import of a re-export module keeps it alive" {
	const graph = importGraph([["/main.ms", "*", "lib", "/hub.ms"], ["/hub.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert moduleAlive(graph, "/hub.ms");
}

test "module imported for a dead name stays dead" {
	const graph = importGraph([["/main.ms", "unused", "unused", "/hub.ms"], ["/hub.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert !moduleAlive(graph, "/hub.ms");
}

test "re-export cycle terminates" {
	const graph = importGraph([["/main.ms", "ghost", "ghost", "/a.ms"], ["/a.ms", "*", "*", "/b.ms"], ["/b.ms", "*", "*", "/a.ms"]]);
	assert !moduleAlive(graph, "/a.ms");
}

test "side-effect import from a live module keeps its target alive" {
	const graph = importGraph([["/main.ms", "/side.ms"], ["/side.ms"]]);
	assert moduleAlive(graph, "/side.ms");
}

test "side-effect imports keep every module of their chain alive" {
	const graph = importGraph([["/main.ms", "/mid.ms"], ["/mid.ms", "/side.ms"], ["/side.ms"]]);
	assert moduleAlive(graph, "/mid.ms");
	assert moduleAlive(graph, "/side.ms");
}

test "side-effect import from a dead module keeps nothing" {
	const graph = importGraph([
		["/main.ms", "unused", "unused", "/dead.ms"],
		["/dead.ms", "/side.ms"],
		["/side.ms"],
	]);
	assert !moduleAlive(graph, "/dead.ms");
	assert !moduleAlive(graph, "/side.ms");
}

test "side-effect import of a re-export hub keeps its target alive" {
	const graph = importGraph([
		["/main.ms", "add", "add", "/hub.ms"],
		["/hub.ms", "add", "add", "/impl.ms"],
		["/hub.ms", "/native.ms"],
		["/native.ms"],
		["/impl.ms"],
	]);
	assert moduleAlive(graph, "/native.ms");
}

test "side-effect import cycle terminates" {
	const graph = importGraph([["/main.ms", "/a.ms"], ["/a.ms", "/b.ms"], ["/b.ms", "/a.ms"]]);
	assert moduleAlive(graph, "/a.ms");
	assert moduleAlive(graph, "/b.ms");
}
