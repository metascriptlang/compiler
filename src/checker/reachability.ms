// Global Dead Code Elimination — Reachability Analysis
//
// Computes an AliveSet of symbols by walking ASTs from roots (top-level
// stmts, test decls, exported symbols).

import { Node, NodeKind, NodeFlag, TypeKind, DeclKind, ProgramData, FunctionDeclData, HiddenStdConvData,
	ExportDeclData, VariableDeclData, ObjectLiteralData, ArrayLiteralData, ClassDeclData, ActorDeclData,
	CallExprData, MemberExprData, NewExprData, BinaryExprData, DecoratedDeclData, ExternDeclData, IdentifierData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { getDeclName } from "./collectPass";
import {
	AliveSet,
	CTypeInfoDemand,
	TypeInfoKind,
	createAliveSet,
	aliveSetAddSym,
	aliveSetHasSym,
	aliveSetAddModule,
	aliveSetHasDecl,
	aliveSetHasModule,
	aliveSetModuleCount,
} from "../codegen/c/context";
import { ModuleGraph, findModule, createModuleGraph, createModule, addModule, createImportEntry } from "../module/graph";
import { refArrayCellKey, refArrayCellOp, requireOpByKey, getOpByKey, typeInfoSubject, objectTypeInfoKey, isPrivateTypeInfoSubject, arcCellKey } from "../codegen/c/types";
import { hasFlag, SymbolFlag, makeSymbol } from "./symbol";
import { hasGenericParams, isMaybeType, arrayElementNeedsCleanup, unwrapPointerLikeForVariant, unwrapRefNullUnion, awaitedType, createArray, createRef, hasAsgnFlag, getAttachedOp, peelTransparentInstance, unwrapRef } from "./types";
import { SymbolKind, Symbol, Type, CallingConvention, AttachedOp } from "../ast/node";
import { monoInstanceName } from "../monomorphize/registry";
import { DispMethodEntry, dispatchEntryFor, dispatchOverridesFor } from "./context";

export function functionDeclIsAlive(aliveSet: Readonly<AliveSet>, modulePath: string, node: Readonly<Node>): boolean {
	if (!aliveSet.enabled) return true;
	const name = (node.data as FunctionDeclData).fnName;
	const sym = node.resolvedSym;
	return aliveSetHasDecl(aliveSet, sym, name);
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
let _imageModules = new HashSet<string>();

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
		if (sym != null) markReferenced(sym, modulePath);
		return;
	}

	// CallExpr — walk callee and arguments
	if (k == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		const magic = cd.callee.resolvedSym != null ? cd.callee.resolvedSym.builtinKind : "";
		if (magic == "BoxRefArray" && cd.arguments.length > 0 && cd.arguments[0].nodeType != null) {
			markRefArrayCell(cd.arguments[0].nodeType, modulePath);
		} else if (magic == "BoxArc" && cd.arguments.length > 0 && cd.arguments[0].nodeType != null) {
			markArcCell(cd.arguments[0].nodeType, modulePath);
		} else if (magic == "BoxLocked" && node.nodeType != null && node.nodeType.typeReturn != null) {
			markArcCell(node.nodeType.typeReturn, modulePath);
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
		markAllocationInfo(node.nodeType, modulePath);
		return;
	}

	if (k == NodeKind.ObjectLiteral) {
		markAllocationInfo(node.nodeType, modulePath);
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
		markObjectTypeInfo(node.nodeType, modulePath);
		walkChildrenGeneric(node, modulePath);
		return;
	}

	if (k == NodeKind.BinaryExpr && (node.data as BinaryExprData).operator == "instanceof") {
		const rhs = (node.data as BinaryExprData).right;
		markObjectTypeInfo(rhs.resolvedSym != null ? rhs.resolvedSym.symbolType : rhs.nodeType, modulePath);
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

function moveCellOwnerIntoCore(key: string, demander: string): void {
	if (_imageModules.size == 0 || _imageModules.has(demander)) return;
	for (const demand of _aliveSet.typeInfos) {
		if (demand.key != key) continue;
		if (!_imageModules.has(demand.owner)) return;
		demand.owner = demander;
		aliveSetAddModule(_aliveSet, demander);
		markReferenced(demand.destroy, demander);
		if (demand.trace != null) markReferenced(demand.trace, demander);
		return;
	}
}

function markRefArrayCell(arrT: Type, modulePath: string): void {
	const key = refArrayCellKey(arrT);
	if (_aliveSet.typeInfoKeys.has(key)) {
		moveCellOwnerIntoCore(key, modulePath);
		return;
	}
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
	const demand: CTypeInfoDemand = { kind: TypeInfoKind.RefArrayCell, subject: createRef(arrT), key, owner, cName: "", destroy, trace, baseKey: "", moduleLocal: false };
	_aliveSet.typeInfos.push(demand);
	aliveSetAddModule(_aliveSet, owner);
	markReferenced(destroy, owner);
	if (trace != null) markReferenced(trace, owner);
}

function markArcCell(pointee: Type, modulePath: string): void {
	const key = arcCellKey(pointee);
	if (_aliveSet.typeInfoKeys.has(key)) return;
	const destroy = arrayElementNeedsCleanup(pointee) ? getOpByKey(pointee, AttachedOp.AttachedDestructor) : null;
	const owner = _singleModule != "" ? _singleModule : modulePath;
	_aliveSet.typeInfoKeys.add(key);
	const demand: CTypeInfoDemand = { kind: TypeInfoKind.ArcCell, subject: pointee, key, owner, cName: "", destroy, trace: null, baseKey: "", moduleLocal: false };
	_aliveSet.typeInfos.push(demand);
	aliveSetAddModule(_aliveSet, owner);
	if (destroy != null) markReferenced(destroy, owner);
}

function markPromiseAllResult(resultType: Type, modulePath: string): void {
	let collected = awaitedType(resultType);
	if (collected != null && collected.kind == TypeKind.Ref && collected.typeReturn != null) collected = collected.typeReturn;
	if (collected == null || collected.kind != TypeKind.Array || collected.typeReturn == null) return;
	const elem = collected.typeReturn;
	if (elem.kind != TypeKind.Struct || elem.typeName == "" || !hasAsgnFlag(elem)) return;
	markReferenced(requireOpByKey(createArray(elem), AttachedOp.AttachedDestructor), modulePath);
}

// Union narrow/project sites make codegen emit variant Copy/Destroy calls with no AST edge.
function markUnionHookEdges(t: Type): void {
	for (const vt of t.typeChildren) {
		if (vt == null) continue;
		let vbase = vt;
		if ((vt.kind == TypeKind.Ref || vt.kind == TypeKind.Ptr) && vt.typeReturn != null) vbase = vt.typeReturn;
		markOpEdge(getOpByKey(vbase, AttachedOp.AttachedAsgn));
		markOpEdge(getOpByKey(vbase, AttachedOp.AttachedDestructor));
		markOpEdge(getOpByKey(vbase, AttachedOp.AttachedTrace));
	}
	if (t.typeName.length > 0) {
		markOpEdge(getOpByKey(t, AttachedOp.AttachedAsgn));
		markOpEdge(getOpByKey(t, AttachedOp.AttachedSink));
		markOpEdge(getOpByKey(t, AttachedOp.AttachedWasMoved));
	}
}

function markOpEdge(op: Symbol | null): void {
	if (op != null) markSymAndWalk(op, "");
}

function markRematerializedMemberTypeInfo(conv: Type | null, modulePath: string): void {
	if (conv == null || conv.kind == TypeKind.Union) return;
	const member = unwrapPointerLikeForVariant(conv);
	if (member != null && member != conv && member.kind == TypeKind.Struct) markObjectTypeInfo(member, modulePath);
}

function opOwner(op: Symbol | null, fallback: string): string {
	if (op == null) return fallback;
	const home = opHome(op, fallback);
	return home != "" ? home : fallback;
}

function ownModuleOp(op: Symbol | null, modulePath: string): Symbol | null {
	if (op == null) return null;
	return opHome(op, modulePath) == modulePath ? op : null;
}

function markAllocationInfo(allocated: Type | null, modulePath: string): void {
	if (allocated == null) return;
	let t = peelTransparentInstance(allocated);
	const nullableRef = unwrapRefNullUnion(t);
	if (nullableRef != null) t = nullableRef;
	if (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) markObjectTypeInfo(t, modulePath);
}

function markObjectTypeInfo(type: Type | null, modulePath: string): void {
	const subject = typeInfoSubject(type);
	if (subject == null) return;
	if (subject.sym != null && hasFlag(subject.sym, SymbolFlag.ImportC)) return;
	const key = objectTypeInfoKey(subject, modulePath);
	if (_aliveSet.typeInfoKeys.has(key)) return;
	const isPrivate = isPrivateTypeInfoSubject(subject);
	const destroy = isPrivate ? ownModuleOp(getOpByKey(subject, AttachedOp.AttachedDestructor), modulePath) : getOpByKey(subject, AttachedOp.AttachedDestructor);
	const trace = isPrivate ? ownModuleOp(getOpByKey(subject, AttachedOp.AttachedTrace), modulePath) : getOpByKey(subject, AttachedOp.AttachedTrace);
	let owner = _singleModule != "" ? _singleModule : modulePath;
	if (!isPrivate && _singleModule == "") {
		if (subject.sym != null && subject.sym.modulePath != "") owner = subject.sym.modulePath;
		else owner = opOwner(destroy, modulePath);
	}
	_aliveSet.typeInfoKeys.add(key);
	let baseKey = "";
	const base = classBaseOf(subject);
	if (base != null) {
		markObjectTypeInfo(base, modulePath);
		baseKey = objectTypeInfoKey(typeInfoSubject(base)!, modulePath);
	}
	const demand: CTypeInfoDemand = { kind: TypeInfoKind.Object, subject, key, owner, cName: "", destroy, trace, baseKey, moduleLocal: isPrivate };
	_aliveSet.typeInfos.push(demand);
	aliveSetAddModule(_aliveSet, owner);
	if (destroy != null) markReferenced(destroy, owner);
	if (trace != null) markReferenced(trace, owner);
}

function classBaseOf(subject: Type): Type | null {
	if (subject.kind != TypeKind.Struct || subject.typeExtra == null) return null;
	const inner = subject.typeExtra.kind == TypeKind.Ref && subject.typeExtra.typeReturn != null ? subject.typeExtra.typeReturn : subject.typeExtra;
	if (inner.kind != TypeKind.Struct || inner.typeName == "") return null;
	return inner;
}

// Walk all children of a node generically via shared forEachChild
function walkChildrenGeneric(node: Node, modulePath: string): void {
	forEachChild(node, (child: Node): void => {
		walkBody(child, modulePath);
	});
}

function walkNamedDecls(modulePath: string, name: string): void {
	const key = modulePath + ":" + name;
	if (visitedHas(key)) return;
	visitedAdd(key);
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
		markObjectTypeInfo(ov.classSym.symbolType, ov.classSym.modulePath);
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
	if (home != "") aliveSetAddModule(_aliveSet, home);
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
	if (decl.resolvedSym == null) throw new Error(`internal: root declaration '${topDeclName(decl)}' of ${modulePath} has no symbol`);
	markSymAndWalk(decl.resolvedSym, modulePath);
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
		throw new Error(`internal: declaration '${name}' of ${modulePath} reached reachability without a symbol`);
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
		markObjectTypeInfo(found.resolvedSym.symbolType, modulePath);
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
	imageModules: string[] = [],
): AliveSet {
	const rootFunctions = new HashSet<Symbol>();
	for (const sym of exportRootFunctions) {
		rootFunctions.add(sym);
		for (const overload of sym.overloads) rootFunctions.add(overload);
	}
	_aliveSet = createAliveSet();
	_aliveSet.enabled = true;
	_visitedSet = new HashSet<string>();
	_visitedSyms = new HashSet<Symbol>();
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
			// decl) so the kind roots below see the real decl.
			let bare = stmt;
			if (bare.kind == NodeKind.DecoratedDecl) {
				const ddw = bare.data as DecoratedDeclData;
				if (ddw.decoratedNode != null) bare = ddw.decoratedNode;
			}

			if (bare.kind == NodeKind.FunctionDecl) {
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
				globalDestroys.push({ modulePath, block: bare, walked: false });
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
					if (name != "") walkNamedDecls(modulePath, name);
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
	walked: boolean;
}

// A module's global destroys are no root: they run only in a module that is alive for another
// reason, so a module holding nothing but globals stays dead.
function markAliveGlobalDestroys(pending: GlobalDestroysBlock[]): boolean {
	let walked = false;
	for (const entry of pending) {
		if (entry.walked || !aliveSetHasModule(_aliveSet, entry.modulePath)) continue;
		entry.walked = true;
		walkBody(entry.block, entry.modulePath);
		walked = true;
	}
	return walked;
}

function takeReachability(): AliveSet {
	const result = _aliveSet;
	_aliveSet = createAliveSet();
	_singleModule = "";
	_imageModules = new HashSet<string>();
	_visitedSet = new HashSet<string>();
	_visitedSyms = new HashSet<Symbol>();
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
	return sym != null && sym.exportName != "" && !hasFlag(sym, SymbolFlag.ClassInit);
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
	assert aliveSet.enabled;
	assert aliveSet.typeInfos.length == 0;
}

test "a computed alive set that marked no name still drops a module nothing reaches" {
	const aliveSet = computeAliveSet([], [], "/entry.ms", false, createModuleGraph());
	assert aliveSet.computed;
	assert aliveSetHasModule(aliveSet, "/entry.ms");
	assert !aliveSetHasModule(aliveSet, "/other.ms");
}

test "an alive set nobody computed keeps every module" {
	assert aliveSetHasModule(createAliveSet(), "/other.ms");
}

test "a computed alive set keeps the side-effect imports of the entry and their chain" {
	const graph = importGraph([["/entry.ms", "/direct.ms"], ["/entry.ms", "/chain.ms"], ["/chain.ms", "/chained.ms"]]);
	const aliveSet = computeAliveSet([], [], "/entry.ms", false, graph);
	assert aliveSetHasModule(aliveSet, "/direct.ms");
	assert aliveSetHasModule(aliveSet, "/chained.ms");
	assert !aliveSetHasModule(aliveSet, "/other.ms");
}

import { parseSource } from "../parser/statements/validation";
import "../parser/statements/core";
import { spelled, createStruct, createRef, createUnion, nullType, stringType } from "./types";
import { liftedOp, resetHookSyms, objectTypeInfoKey } from "../codegen/c/types";

function allocationOf(source: string): Node {
	const parsed = parseSource(source);
	if (!parsed.ok) throw new Error(parsed.error);
	return parsed.value;
}

function declaredClass(name: string, modulePath: string, fields: string[], base: Type | null): Type {
	const body = createStruct(name, fields, [stringType()], true);
	body.sym = makeSymbol(name, SymbolKind.Interface, body, false);
	body.sym.modulePath = modulePath;
	if (base != null) body.typeExtra = createRef(base);
	return body;
}

test "nullable reference allocation demands its concrete TypeInfo from the declaring module" {
	const program = allocationOf("let value = { label: \"held\" };");
	const allocation = ((program.data as ProgramData).programStmts[0].data as VariableDeclData).initializer;
	const body = declaredClass("Holder", "owner.ms", ["label"], null);
	allocation.nodeType = createUnion([createRef(body), nullType()]);
	const alive = computeAliveSet([program], ["user.ms"], "user.ms", false, createModuleGraph());
	assert alive.typeInfos.length == 1;
	assert alive.typeInfos[0].key == objectTypeInfoKey(body, "user.ms");
	assert alive.typeInfos[0].owner == "owner.ms";
}

test "an allocation demands its base class TypeInfo and names it" {
	const program = allocationOf("let value = { label: \"held\" };");
	const allocation = ((program.data as ProgramData).programStmts[0].data as VariableDeclData).initializer;
	const parent = declaredClass("Parent", "parent.ms", ["label"], null);
	const child = declaredClass("Child", "child.ms", ["label"], parent);
	allocation.nodeType = createRef(child);
	const alive = computeAliveSet([program], ["user.ms"], "user.ms", false, createModuleGraph());
	assert alive.typeInfos.length == 2;
	let childInfo: CTypeInfoDemand | null = null;
	for (const info of alive.typeInfos) {
		if (info.owner == "child.ms") childInfo = info;
	}
	assert childInfo != null;
	assert childInfo!.baseKey == objectTypeInfoKey(parent, "user.ms");
}

test "a lambda environment class is local to the module that lifted it" {
	const program = allocationOf("let value = { label: \"held\" };");
	const allocation = ((program.data as ProgramData).programStmts[0].data as VariableDeclData).initializer;
	const env = spelled(createStruct("$Env_run_shared", ["label"], [stringType()], true));
	allocation.nodeType = createRef(env);
	const alive = computeAliveSet([program], ["user.ms"], "user.ms", false, createModuleGraph());
	assert alive.typeInfos.length == 1;
	assert alive.typeInfos[0].moduleLocal;
	assert alive.typeInfos[0].owner == "user.ms";
	assert alive.typeInfos[0].key == objectTypeInfoKey(env, "user.ms");
	assert objectTypeInfoKey(env, "user.ms") != objectTypeInfoKey(env, "other.ms");
}

function bindIdentifiers(node: Node, name: string, sym: Symbol): void {
	if (node.kind == NodeKind.Identifier && (node.data as IdentifierData).name == name) node.resolvedSym = sym;
	forEachChild(node, (child: Node): void => {
		bindIdentifiers(child, name, sym);
	});
}

test "a generated op is alive through the symbol that references it" {
	const parsed = parseSource("hookDestroy(); function hookDestroy(): void {} function deadDestroy(): void {}");
	assert parsed.ok;
	if (!parsed.ok) return;
	resetHookSyms();
	const liveBody = createStruct("HookLive", ["v"], [stringType()], true);
	liveBody.sym = makeSymbol("HookLive", SymbolKind.Interface, liveBody, false);
	const deadBody = createStruct("HookDead", ["v"], [stringType()], true);
	deadBody.sym = makeSymbol("HookDead", SymbolKind.Interface, deadBody, false);
	const live = liftedOp(liveBody, AttachedOp.AttachedDestructor, "hookDestroy", null);
	const dead = liftedOp(deadBody, AttachedOp.AttachedDestructor, "deadDestroy", null);
	const stmts = (parsed.value.data as ProgramData).programStmts;
	stmts[1].resolvedSym = live;
	stmts[2].resolvedSym = dead;
	bindIdentifiers(stmts[0], "hookDestroy", live);
	const alive = computeAliveSet([parsed.value], ["owner.ms"], "owner.ms", false, createModuleGraph());
	assert aliveSetHasSym(alive, live);
	assert !aliveSetHasSym(alive, dead);
}

test "a function named main is alive only through a reference" {
	const parsed = parseSource("function main(): void {} function used(): void {} used();");
	assert parsed.ok;
	if (!parsed.ok) return;
	const stmts = (parsed.value.data as ProgramData).programStmts;
	const main = makeSymbol("main", SymbolKind.Function, null, false);
	const used = makeSymbol("used", SymbolKind.Function, null, false);
	stmts[0].resolvedSym = main;
	stmts[1].resolvedSym = used;
	bindIdentifiers(stmts[2], "used", used);
	const alive = computeAliveSet([parsed.value], ["entry.ms"], "entry.ms", false, createModuleGraph());
	assert aliveSetHasSym(alive, used);
	assert !aliveSetHasSym(alive, main);
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
	const impl = allocationOf("function add(): void {}");
	const add = (impl.data as ProgramData).programStmts[0];
	add.resolvedSym = makeSymbol("add", SymbolKind.Function, null, false);
	_aliveSet = createAliveSet();
	_aliveSet.enabled = true;
	declIndexBuild([impl], ["/impl.ms"]);
	aliveSetAddModule(_aliveSet, "/main.ms");
	aliveSetAddModule(_aliveSet, "/impl.ms");
	aliveSetAddSym(_aliveSet, add.resolvedSym);
	markImportedModulesAlive(graph);
	const alive = aliveSetHasModule(_aliveSet, modulePath);
	_aliveSet = createAliveSet();
	declIndexBuild([], []);
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
