// Global Dead Code Elimination — Reachability Analysis
//
// Computes an AliveSet of "modulePath:symbolName" keys by walking ASTs
// starting from roots (main, top-level stmts, test decls, exported symbols).
// Cross-module references traced via ImportDecl source paths.

import { Node, NodeKind, NodeFlag, TypeKind, DeclKind, ProgramData, FunctionDeclData, HiddenStdConvData,
	ExportDeclData, IdentifierData, VariableDeclData, ObjectLiteralData, ArrayLiteralData, ClassDeclData, ActorDeclData,
	CallExprData, MemberExprData, NewExprData, DecoratedDeclData, ExternDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { getDeclName } from "./collectPass";
import { AliveSet, createAliveSet, aliveSetAdd, aliveSetAddModule, aliveSetHas, aliveSetHasModule } from "../codegen/c/context";
import { ModuleGraph, findModule, createModuleGraph, createModule, addModule, createImportEntry } from "../module/graph";
import { hookBaseCName, hookBaseCNameOfSym } from "../codegen/c/types";
import { hasFlag, SymbolFlag, initFnName } from "./symbol";
import { isMaybeType, unwrapRefNullUnion } from "./types";
import { SymbolKind, Type, CallingConvention } from "../ast/node";
import { mangleMonoName } from "../monomorphize/registry";
import { dispatchEntryForLiftedName, dispatchOverridesFor } from "./context";

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

function declIndexBuild(programs: Node[], paths: string[]): void {
	_declHead = new HashMap<string, int32>();
	_declNodes = [];
	_declNext = [];
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
			_declHead.set(key, _declNodes.length - 1);
		}
	}
}

// ===== Visited Set (Set-based for O(1) lookup) =====

let _visitedSet: HashSet<string> = new HashSet<string>();

function visitedHas(key: string): boolean {
	return _visitedSet.has(key);
}

function visitedAdd(key: string): void {
	_visitedSet.add(key);
}

// ===== Module-level state (avoids closure capture of value-type arrays/structs) =====

let _aliveSet: AliveSet = createAliveSet();

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
		const id = node.data as IdentifierData;
		const sym = node.resolvedSym;
		if (sym != null && hasFlag(sym, SymbolFlag.GeneratedOp)) {
			markAndWalk(modulePath, sym.name);
			const hookMod = nameIndexLookup(sym.name);
			if (hookMod != "" && hookMod != modulePath) {
				markAndWalk(hookMod, sym.name);
			}
			return;
		}
		if (sym != null) {
			// Use the symbol's home module + original declared name.
			// originalName handles aliases: import { printNode as printAstNode }
			// → sym.name="printAstNode", sym.originalName="printNode"
			// We need "printNode" to find the declaration in the source module.
			const targetName = (sym.originalName != "" && sym.originalName != null) ? sym.originalName : sym.name;
			if (sym.modulePath != "" && sym.modulePath != modulePath) {
				markAndWalk(sym.modulePath, targetName);
			} else {
				markAndWalk(modulePath, targetName);
			}
		} else if (id.name.length > 0) {
			// No resolvedSym: transform-generated or generic-instantiated identifiers.
			// Try current module first, then use pre-built name index for cross-module.
			markAndWalk(modulePath, id.name);
			const crossMod = nameIndexLookup(id.name);
			if (crossMod != "" && crossMod != modulePath) {
				markAndWalk(crossMod, id.name);
			}
		}
		return;
	}

	// CallExpr — walk callee and arguments
	if (k == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		walkBody(cd.callee, modulePath);
		for (const arg of cd.arguments) {
			walkBody(arg, modulePath);
		}
		return;
	}

	// NewExpr — class constructor expressions need `<className>_init` alive.
	// `methodToFunction` transform lifts the ctor body to a top-level
	// `<className>_init(this, ...)` FunctionDecl AFTER reachability runs,
	// so the lifted name isn't auto-discoverable here. We seed it explicitly
	// when a class with `HasConstructor` is constructed: same mark-alive
	// pattern MemberExpr uses for class methods, but keyed off the ctor's
	// future synthetic name.
	if (k == NodeKind.NewExpr) {
		const nd = node.data as NewExprData;
		walkBody(nd.newCallee, modulePath);
		for (const arg of nd.newArguments) {
			walkBody(arg, modulePath);
		}
		if (nd.newCallee.resolvedSym != null) {
			const classSym = nd.newCallee.resolvedSym;
			const className = (classSym.originalName != "" && classSym.originalName != null) ? classSym.originalName : classSym.name;
			const initName = initFnName(className);
			const ctorMod = classSym.modulePath != "" ? classSym.modulePath : modulePath;
			markAndWalk(ctorMod, initName);
			let gi = node.nodeType;
			if (gi != null && (gi.kind == TypeKind.Ref || gi.kind == TypeKind.Ptr) && gi.typeReturn != null) gi = gi.typeReturn;
			if (gi != null && gi.kind == TypeKind.GenericInstance && gi.typeName != "" && gi.typeChildren.length > 0) {
				const monoName = mangleMonoName(gi.typeName, gi.typeChildren);
				markAndWalk(ctorMod, monoName);
				markAndWalk(ctorMod, initFnName(monoName));
			}
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

	// MemberExpr — walk object + mark resolved extension/class method
	if (k == NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		walkBody(md.object, modulePath);
		if (node.resolvedSym != null) {
			const sym2 = node.resolvedSym;
			const targetName2 = (sym2.originalName != "" && sym2.originalName != null) ? sym2.originalName : sym2.name;
			if (sym2.modulePath != "" && sym2.modulePath != modulePath) {
				markAndWalk(sym2.modulePath, targetName2);
			} else {
				markAndWalk(modulePath, targetName2);
			}
		} else if (md.property != "") {
			// No resolvedSym (generic instantiation clears it).
			// Search all modules for the method — extension methods may be cross-module.
			// No resolvedSym — use pre-built name index for cross-module extension methods.
			const crossMod2 = nameIndexLookup(md.property);
			if (crossMod2 != "") {
				markAndWalk(crossMod2, md.property);
			} else {
				markAndWalk(modulePath, md.property);
			}
		}
		return;
	}

	// For all other nodes: walk children generically via forEachChild
	// NOTE: forEachChild uses a callback — we pass module-level state
	// instead of closure-captured value-type arrays to avoid use-after-free
	walkChildrenGeneric(node, modulePath);
}

// Allocation site → <T>TypeInfo edge. The emitted allocation references the
// type's TypeInfo global, whose initializer references <T>Destroy/<T>Trace —
// the only AST path to ref-type hooks (msDecref dispatches through TypeInfo
// at runtime, so no direct call site exists). Mirrors codegen's on-demand
// TypeInfo emission: mark only when the TypeInfo decl really exists.
// Array sequence hooks (msStringArray*/msRefArray*/…ArrayDestroy etc.) are
// per-module static helpers whose demand arises inside codegen (cell TypeInfos
// name them directly, no AST edge exists). Keep them rooted; the linker strips
// unreferenced static functions, so dead ones cost nothing. Mirror of
// isArraySeqHook in codegen/c/declarations.ms — keep in lock-step.
function isArraySeqHookName(name: string): boolean {
	if (name == "msStringArrayDestroy" || name == "msRefArrayDestroy" || name == "msNumberArrayDestroy") return false;
	return name.endsWith("ArrayDestroy") || name.endsWith("ArrayCopy") ||
		name.endsWith("ArraySink") || name.endsWith("ArrayWasMoved");
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

function markTypeInfoEdge(node: Node, modulePath: string): void {
	let t = node.nodeType;
	if (t == null) return;
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
		const mono = mangleMonoName(t.typeName, t.typeChildren);
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
	let bt = t.typeExtra;
	let depth = 0;
	while (bt != null && depth < 64) {
		let inner = bt;
		if (inner.kind == TypeKind.Ref && inner.typeReturn != null) inner = inner.typeReturn;
		if (inner.kind != TypeKind.Struct || inner.typeName == "") break;
		const btiName = inner.typeName + "TypeInfo";
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

	// Dispatch bucket edge (Nim cgmeth: a reachable base method makes every
	// override + its class TypeInfo reachable — the msDisp_* if-chain
	// references them all regardless of static call sites).
	const dde = dispatchEntryForLiftedName(name);
	if (dde != null && !dde.overloaded) {
		for (const ov of dispatchOverridesFor(dde.className, dde.methodName)) {
			const ovHome = nameIndexLookup(ov.sym.name);
			if (ovHome != "") {
				markAndWalk(ovHome, ov.sym.name);
			}
			const tiName = ov.className + "TypeInfo";
			const tiHome = nameIndexLookup(tiName);
			if (tiHome != "") {
				markAndWalk(tiHome, tiName);
			}
		}
	}

	// Walk ALL declarations with this name (handles overloaded functions)
	let di = _declHead.get(key) ?? -1;
	while (di >= 0) {
		const found = _declNodes[di];
		di = _declNext[di];
		walkBody(found, modulePath);
		// When a class becomes alive, also mark `<className>_init` alive —
		// `methodToFunction` lifts the ctor body into a top-level
		// FunctionDecl with that name and removes the ConstructorDecl from
		// classBody, so the name is not discoverable from the class node.
		// Every class carries an `_init` (ctorLower synthesizes one when
		// the source has no constructor), and marking a name that has no
		// declaration is inert. Required for both `new C(...)` and
		// `super(args)` from a child class — which codegen lowers to
		// `<Parent>_init(this, args)`, so any reachable parent in the
		// inheritance chain needs its `_init` alive too.
		if (found.kind == NodeKind.ClassDecl) {
			// Recursive: markAndWalk so the lifted `_init` body is also
			// visited. The ctor body may contain `super(args)` whose
			// parent class needs to be reached + that parent's `_init`
			// chained alive too. Without recursion, A → B → C inheritance
			// chains stop at the leaf and parent `_init`s drop out.
			markAndWalk(modulePath, initFnName(name));
		}
		// Actors: actorLower erased the NewExpr before this walk runs, so
		// no allocation-site edge fires — but a spawned actor's TypeInfo
		// is always demanded. Marking it walks its initializer, which
		// marks Destroy/Trace via the Identifier fallback.
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

function reachesAliveThroughReexports(graph: ModuleGraph, modulePath: string, name: string, memo: HashMap<string, boolean>): boolean {
	const anyName = name == ANY_EXPORT;
	if (anyName ? aliveSetHasModule(_aliveSet, modulePath) : aliveSetHas(_aliveSet, modulePath, name)) return true;
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

// ===== Public API =====

export function computeAliveSet(programs: Node[], paths: string[], entryPath: string, isTest: boolean, graph: ModuleGraph): AliveSet {
	_aliveSet = createAliveSet();
	_visitedSet = new HashSet<string>();
	nameIndexBuild(programs, paths);
	declIndexBuild(programs, paths);
	aliveSetAddModule(_aliveSet, entryPath);

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
					markAndWalk(modulePath, "main");
					continue;
				}
			}
			// Also check exported main under ExportDecl
			if (modulePath == entryPath && bare.kind == NodeKind.ExportDecl) {
				const ed = bare.data as ExportDeclData;
				if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.FunctionDecl) {
					const fd = ed.exportedDecl.data as FunctionDeclData;
					if (fd.fnName == "main") {
						markAndWalk(modulePath, "main");
						continue;
					}
				}
			}

			// Root 2: Compiler-generated functions — always alive.
			// Must match isDeclAlive exemptions in codegen/c/declarations.ms exactly:
			// $prefix (lambda lifting), =prefix (operators), __prefix (builtinLower),
			// DRC lifecycle suffixes, generic instantiations (__ in middle of name).
			if (bare.kind == NodeKind.FunctionDecl) {
				const fd2 = bare.data as FunctionDeclData;
				const fn = fd2.fnName;
				if (fn.length > 0 && fn.slice(0, 1) == "$") {
					const isLifted = (fn.length >= 8 && fn.slice(0, 8) == "$lifted_")
						|| (fn.length >= 4 && fn.slice(0, 4) == "$fn_");
					if (!isLifted) {
						walkBody(bare, modulePath);
					}
					continue;
				}
				if (isArraySeqHookName(fn)) {
					walkBody(bare, modulePath);
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
			if (isTopLevelStatement(initStmt)) {
				walkBody(bare, modulePath);
				continue;
			}

			if (exportsCSymbol(bare)) {
				markAndWalk(modulePath, getDeclName(bare));
				continue;
			}

			// Root 5: Exported declarations in ENTRY MODULE only.
			// Dependency module exports are NOT roots (reference parity: only sfExportc/sfCompilerProc).
			// They become alive through transitive tracing from main() or top-level statements.
			if (modulePath == entryPath && isExportedDecl(bare)) {
				const name = getDeclName(bare);
				if (name != "") {
					markAndWalk(modulePath, name);
				}
			}
		}
	}

	markReexportConduitsAlive(graph);

	const result = _aliveSet;
	_aliveSet = createAliveSet();
	_visitedSet = new HashSet<string>();
	_nameIndex = new HashMap<string, string>();
	_declHead = new HashMap<string, int32>();
	_declNodes = [];
	_declNext = [];
	return result;
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

function conduitGraph(edges: string[][]): ModuleGraph {
	const graph = createModuleGraph();
	for (const e of edges) {
		let mod = findModule(graph, e[0]);
		if (mod == null) {
			mod = createModule(e[0]);
			addModule(graph, mod);
		}
		if (e.length == 4) mod.imports.push(createImportEntry([e[1]], [e[2]], e[3], e[3]));
	}
	return graph;
}

function conduitAlive(graph: ModuleGraph, conduit: string): boolean {
	_aliveSet = createAliveSet();
	aliveSetAdd(_aliveSet, "/main.ms", "main");
	aliveSetAdd(_aliveSet, "/impl.ms", "add");
	markReexportConduitsAlive(graph);
	const alive = aliveSetHasModule(_aliveSet, conduit);
	_aliveSet = createAliveSet();
	return alive;
}

test "named re-export on the path to an alive symbol keeps its module alive" {
	const graph = conduitGraph([["/main.ms", "add", "add", "/hub.ms"], ["/hub.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert conduitAlive(graph, "/hub.ms");
}

test "aliased re-export resolves the source name" {
	const graph = conduitGraph([["/main.ms", "plus", "plus", "/hub.ms"], ["/hub.ms", "add", "plus", "/impl.ms"], ["/impl.ms"]]);
	assert conduitAlive(graph, "/hub.ms");
}

test "star re-export on the path to an alive symbol keeps its module alive" {
	const graph = conduitGraph([["/main.ms", "add", "add", "/hub.ms"], ["/hub.ms", "*", "*", "/impl.ms"], ["/impl.ms"]]);
	assert conduitAlive(graph, "/hub.ms");
}

test "every module of a re-export chain stays alive" {
	const graph = conduitGraph([["/main.ms", "add", "add", "/outer.ms"], ["/outer.ms", "add", "add", "/inner.ms"], ["/inner.ms", "*", "*", "/impl.ms"], ["/impl.ms"]]);
	assert conduitAlive(graph, "/outer.ms");
	assert conduitAlive(graph, "/inner.ms");
}

test "two hubs sharing one inner hub both stay alive" {
	const graph = conduitGraph([["/main.ms", "add", "add", "/hubA.ms"], ["/main.ms", "add", "add2", "/hubB.ms"],
		["/hubA.ms", "add", "add", "/inner.ms"], ["/hubB.ms", "add", "add", "/inner.ms"], ["/inner.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert conduitAlive(graph, "/hubA.ms");
	assert conduitAlive(graph, "/hubB.ms");
}

test "namespace import of a re-export module keeps it alive" {
	const graph = conduitGraph([["/main.ms", "*", "lib", "/hub.ms"], ["/hub.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert conduitAlive(graph, "/hub.ms");
}

test "module imported for a dead name stays dead" {
	const graph = conduitGraph([["/main.ms", "unused", "unused", "/hub.ms"], ["/hub.ms", "add", "add", "/impl.ms"], ["/impl.ms"]]);
	assert !conduitAlive(graph, "/hub.ms");
}

test "re-export cycle terminates" {
	const graph = conduitGraph([["/main.ms", "ghost", "ghost", "/a.ms"], ["/a.ms", "*", "*", "/b.ms"], ["/b.ms", "*", "*", "/a.ms"]]);
	assert !conduitAlive(graph, "/a.ms");
}
