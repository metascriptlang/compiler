// Global Dead Code Elimination — Reachability Analysis
//
// Computes an AliveSet of "modulePath:symbolName" keys by walking ASTs
// starting from roots (main, top-level stmts, test decls, exported symbols).
// Cross-module references traced via ImportDecl source paths.

import { Node, NodeKind, NodeFlag, TypeKind, DeclKind, ProgramData, FunctionDeclData, ImportDeclData,
	ExportDeclData, IdentifierData, VariableDeclData, ObjectLiteralData, ArrayLiteralData, ClassDeclData, ActorDeclData,
	CallExprData, MemberExprData, NewExprData, DecoratedDeclData, ExternDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { getDeclName } from "./collectPass";
import { AliveSet, createAliveSet, aliveSetAdd } from "../codegen/c/context";
import { hookBaseCName, hookBaseCNameOfSym } from "../codegen/c/types";
import { hasFlag, SymbolFlag, initFnName } from "./symbol";
import { SymbolKind, Type } from "../ast/node";
import { mangleMonoName } from "../monomorphize/registry";
import { dispatchEntryForLiftedName, dispatchOverridesFor } from "./context";

// ===== Module Index =====
// Maps module path to its program AST for cross-module tracing.

interface ModuleIndex {
	paths: string[];
	programs: Node[];
}

// Program lookup cache — parallel arrays
let _progCacheKeys: string[] = [];
let _progCacheVals: Node[] = [];

// ===== Global Name Index =====
// Pre-built name→modulePath index for O(1) cross-module lookup.
// Replaces the O(n*m) linear scan of all modules for unresolved identifiers.
// Built once at the start of computeAliveSet.
let _nameIndex: HashMap<string, string> = new HashMap<string, string>();

function nameIndexBuild(idx: ModuleIndex): void {
	_nameIndex = new HashMap<string, string>();
	for (let m = 0; m < idx.programs.length; m += 1) {
		const prog = idx.programs[m];
		if (prog == null) continue;
		const pd = prog.data as ProgramData;
		const modPath = idx.paths[m];
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

function findProgram(idx: ModuleIndex, path: string): Node {
	for (let c = 0; c < _progCacheKeys.length; c += 1) {
		if (_progCacheKeys[c] == path) return _progCacheVals[c];
	}
	for (let i = 0; i < idx.paths.length; i += 1) {
		if (idx.paths[i] == path) {
			_progCacheKeys.push(path);
			_progCacheVals.push(idx.programs[i]);
			return idx.programs[i];
		}
	}
	return null as unknown as Node;
}

// ===== Import Resolution =====
// Given an import specifier in a program, find which module path it resolves to.
// We scan ImportDecl nodes to build a local import map per module.

interface ImportMap {
	names: string[];      // imported symbol name
	sourcePaths: string[]; // resolved module path
}

function buildImportMap(program: Node, modIdx: ModuleIndex): ImportMap {
	const map: ImportMap = { names: [], sourcePaths: [] };
	const d = program.data as ProgramData;
	for (const stmt of d.programStmts) {
		if (stmt == null) continue;
		let importNode = stmt;
		// Unwrap ExportDecl
		if (stmt.kind == NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl != null && ed.exportedDecl.kind == NodeKind.ImportDecl) {
				importNode = ed.exportedDecl;
			}
		}
		if (importNode.kind == NodeKind.ImportDecl) {
			const id = importNode.data as ImportDeclData;
			const resolvedPath = resolveSpecifier(id.importSource, modIdx);
			if (resolvedPath != "") {
				for (let i = 0; i < id.importNames.length; i += 1) {
					map.names.push(id.importNames[i]);
					map.sourcePaths.push(resolvedPath);
				}
			}
		}
	}
	return map;
}

// Resolve an import specifier to a known module path.
// Tries suffix matching: "std/core/string/index" matches "/abs/path/std/core/string/index.ms"
function resolveSpecifier(specifier: string, modIdx: ModuleIndex): string {
	for (let i = 0; i < modIdx.paths.length; i += 1) {
		const p = modIdx.paths[i];
		// Check if path ends with the specifier (with or without extension)
		if (p.endsWith(specifier) || p.endsWith(specifier + ".ms") || p.endsWith(specifier + ".cms") || p.endsWith(specifier + "/index.ms") || p.endsWith(specifier + "/index.cms")) {
			return p;
		}
	}
	return "";
}



// ===== Visited Set (Set-based for O(1) lookup) =====

let _visitedSet: HashSet<string> = new HashSet<string>();

function visitedHas(key: string): boolean {
	return _visitedSet.has(key);
}

function visitedAdd(key: string): void {
	_visitedSet.add(key);
}

// ===== Import Map Cache (avoid rebuilding per markAndWalk call) =====

let _importCacheKeys: string[] = [];
let _importCacheVals: ImportMap[] = [];

function getImportMap(program: Node, modulePath: string): ImportMap {
	for (let c = 0; c < _importCacheKeys.length; c += 1) {
		if (_importCacheKeys[c] == modulePath) return _importCacheVals[c];
	}
	const map = buildImportMap(program, _modIdx);
	_importCacheKeys.push(modulePath);
	_importCacheVals.push(map);
	return map;
}

// ===== Module-level state (avoids closure capture of value-type arrays/structs) =====

let _aliveSet: AliveSet = createAliveSet();
let _modIdx: ModuleIndex = { paths: [], programs: [] };

// ===== Core Walker =====

// Walk a node recursively, marking any referenced declarations alive.
function walkBody(node: Node, modulePath: string, importMap: ImportMap): void {
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
		walkBody(cd.callee, modulePath, importMap);
		for (const arg of cd.arguments) {
			walkBody(arg, modulePath, importMap);
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
		walkBody(nd.newCallee, modulePath, importMap);
		for (const arg of nd.newArguments) {
			walkBody(arg, modulePath, importMap);
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
		walkChildrenGeneric(node, modulePath, importMap);
		return;
	}

	// MemberExpr — walk object + mark resolved extension/class method
	if (k == NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		walkBody(md.object, modulePath, importMap);
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
	walkChildrenGeneric(node, modulePath, importMap);
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
function walkChildrenGeneric(node: Node, modulePath: string, importMap: ImportMap): void {
	forEachChild(node, (child: Node): void => {
		walkBody(child, modulePath, importMap);
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

	// Find ALL declarations with this name (handles overloaded functions)
	const program = findProgram(_modIdx, modulePath);
	if (program == null) return;
	const importMap = getImportMap(program, modulePath);
	const d = program.data as ProgramData;
	for (const stmt of d.programStmts) {
		if (stmt == null) continue;
		const found = matchDeclName(stmt, name);
		if (found != null) {
			walkBody(found, modulePath, importMap);
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
}

// Find a top-level declaration by name in a program AST (first match only).
// Used by the no-resolvedSym fallback search — markAndWalk uses inline loop for all overloads.
function findDecl(program: Node, name: string): Node {
	const d = program.data as ProgramData;
	for (const stmt of d.programStmts) {
		if (stmt == null) continue;
		const found = matchDeclName(stmt, name);
		if (found != null) return found;
	}
	return null as unknown as Node;
}

// Check if a statement is a declaration with the given name. Returns the node to walk.
function matchDeclName(node: Node, name: string): Node {
	if (node == null) return null as unknown as Node;
	const k = node.kind;

	if (k == NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		if (d.fnName == name) return node;
		return null as unknown as Node;
	}
	if (k == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (d.declName == name) return node;
		return null as unknown as Node;
	}
	if (k == NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		if (d.className == name) return node;
		return null as unknown as Node;
	}
	if (k == NodeKind.ActorDecl) {
		const d = node.data as ActorDeclData;
		if (d.actorName == name) return node;
		return null as unknown as Node;
	}
	if (k == NodeKind.InterfaceDecl || k == NodeKind.StructDecl) {
		const d = node.data as { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[] };
		if (d.interfaceName == name) return node;
		return null as unknown as Node;
	}
	if (k == NodeKind.EnumDecl) {
		const d = node.data as { enumName: string, enumMembers: string[] };
		if (d.enumName == name) return node;
		return null as unknown as Node;
	}
	if (k == NodeKind.TypeAliasDecl) {
		const d = node.data as { aliasName: string, aliasType: string, aliasIsDistinct: boolean };
		if (d.aliasName == name) return node;
		return null as unknown as Node;
	}
	if (k == NodeKind.ExternDecl) {
		const d = node.data as ExternDeclData;
		if (d.externName == name) return node;
		return null as unknown as Node;
	}
	// Unwrap ExportDecl
	if (k == NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return matchDeclName(d.exportedDecl, name);
	}
	// Unwrap DecoratedDecl
	if (k == NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return matchDeclName(d.decoratedNode, name);
	}
	return null as unknown as Node;
}

function findImport(importMap: ImportMap, name: string): number {
	for (let i = 0; i < importMap.names.length; i += 1) {
		if (importMap.names[i] == name) return i;
	}
	return -1;
}

// ===== Public API =====

export function computeAliveSet(programs: Node[], paths: string[], entryPath: string, isTest: boolean): AliveSet {
	_aliveSet = createAliveSet();
	_modIdx = { paths, programs };
	_visitedSet = new HashSet<string>();
	_importCacheKeys = [];
	_importCacheVals = [];
	_progCacheKeys = [];
	_progCacheVals = [];
	nameIndexBuild(_modIdx);

	// For each module, find roots and mark them alive
	for (let m = 0; m < programs.length; m += 1) {
		const modulePath = paths[m];
		const program = programs[m];
		if (program == null) continue;
		const d = program.data as ProgramData;
		const importMap = buildImportMap(program, _modIdx);

		for (const stmt of d.programStmts) {
			if (stmt == null) continue;

			// Unwrap DecoratedDecl (module-level @passC/@passL/... wrap the next
			// decl) so name/kind roots below see the real decl — matchDeclName
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
						walkBody(bare, modulePath, importMap);
					}
					continue;
				}
				if (isArraySeqHookName(fn)) {
					walkBody(bare, modulePath, importMap);
					continue;
				}


			}

			// Root 3: TestDecl nodes — in test mode (all modules) or entry module (build mode).
			// Entry module test blocks are wrapped in main() by codegen, so they're always roots.
			if (bare.kind == NodeKind.TestDecl && (isTest || modulePath == entryPath)) {
				walkBody(bare, modulePath, importMap);
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
				walkBody(bare, modulePath, importMap);
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

	const result = _aliveSet;
	_aliveSet = createAliveSet();
	_modIdx = { paths: [], programs: [] };
	_visitedSet = new HashSet<string>();
	_progCacheKeys = [];
	_progCacheVals = [];
	_nameIndex = new HashMap<string, string>();
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
function bakeableEmptyArrayLiteral(init: Node): boolean {
	if (init.kind == NodeKind.ArrayLiteral) {
		const ad = init.data as ArrayLiteralData;
		return ad.elements.length == 0;
	}
	if (init.kind != NodeKind.CallExpr) return false;
	const cd = init.data as CallExprData;
	if (cd.callee.kind != NodeKind.Identifier) return false;
	const id = cd.callee.data as IdentifierData;
	if (id.name != "msBoxRefArray") return false;
	if (cd.arguments.length != 1) return false;
	return bakeableEmptyArrayLiteral(cd.arguments[0]);
}

export function isBakeableAggregateConst(node: Node): boolean {
	const d = node.data as VariableDeclData;
	if (d.declKind != DeclKind.Const) return false;
	if (d.initializer == null) return false;
	const init = d.initializer;
	if (init.kind == NodeKind.ArrayLiteral || init.kind == NodeKind.CallExpr) {
		return bakeableEmptyArrayLiteral(init);
	}
	if (init.kind != NodeKind.ObjectLiteral) return false;
	if ((init.flags & NodeFlag.Closure) != 0) return false;
	const od = init.data as ObjectLiteralData;
	if (od.properties.length == 0) return false;
	for (const prop of od.properties) {
		if (prop == null) return false;
		const bakeable = match (prop.kind) {
			NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral => true,
			NodeKind.ObjectLiteral => (prop.flags & NodeFlag.Closure) != 0,
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

// getDeclName imported from collectPass (single canonical copy)

// ===== Tests =====

test "endsWith helper" {
	assert "foo/bar.ms".endsWith("bar.ms");
	assert "foo/bar.ms".endsWith("foo/bar.ms");
	assert !"foo/bar.ms".endsWith("baz.ms");
}

test "empty programs produce empty alive set" {
	const aliveSet = computeAliveSet([], [], "/entry.ms", false);
	assert aliveSet.entries.length == 0;
}
