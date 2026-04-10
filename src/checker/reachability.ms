// Global Dead Code Elimination — Reachability Analysis
//
// Computes an AliveSet of "modulePath:symbolName" keys by walking ASTs
// starting from roots (main, top-level stmts, test decls, exported symbols).
// Cross-module references traced via ImportDecl source paths.

import { Node, NodeKind, ProgramData, FunctionDeclData, ImportDeclData,
	ExportDeclData, IdentifierData, VariableDeclData, ClassDeclData, ActorDeclData,
	CallExprData, MemberExprData, DecoratedDeclData, ExternDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { getDeclName } from "./collectPass";
import { AliveSet, createAliveSet, aliveSetAdd } from "../codegen/c/context";

// ===== Module Index =====
// Maps module path to its program AST for cross-module tracing.

interface ModuleIndex {
	paths: string[];
	programs: Node[];
}

// Program lookup cache — parallel arrays (works in both Bun and C binary)
let _progCacheKeys: string[] = [];
let _progCacheVals: Node[] = [];

function findProgram(idx: ModuleIndex, path: string): Node {
	for (let c = 0; c < _progCacheKeys.length; c += 1) {
		if (_progCacheKeys[c] === path) return _progCacheVals[c];
	}
	for (let i = 0; i < idx.paths.length; i += 1) {
		if (idx.paths[i] === path) {
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
		if (stmt === null) continue;
		let importNode = stmt;
		// Unwrap ExportDecl
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ImportDecl) {
				importNode = ed.exportedDecl;
			}
		}
		if (importNode.kind === NodeKind.ImportDecl) {
			const id = importNode.data as ImportDeclData;
			const resolvedPath = resolveSpecifier(id.importSource, modIdx);
			if (resolvedPath !== "") {
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

let _visitedSet: Set<string> = new Set<string>();

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
		if (_importCacheKeys[c] === modulePath) return _importCacheVals[c];
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
	if (node === null) return;
	const k = node.kind;

	// Identifier — mark its declaration alive
	if (k === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		const sym = node.resolvedSym;
		if (sym !== null) {
			// Use the symbol's home module + original declared name.
			// originalName handles aliases: import { printNode as printAstNode }
			// → sym.name="printAstNode", sym.originalName="printNode"
			// We need "printNode" to find the declaration in the source module.
			const targetName = (sym.originalName !== "" && sym.originalName !== null) ? sym.originalName : sym.name;
			if (sym.modulePath !== "" && sym.modulePath !== modulePath) {
				markAndWalk(sym.modulePath, targetName);
			} else {
				markAndWalk(modulePath, targetName);
			}
		} else if (id.name.length > 0) {
			// No resolvedSym: transform-generated or generic-instantiated identifiers.
			// Try current module first, then search all modules (cross-module callees
			// inside generic instantiations have resolvedSym cleared during deep clone).
			markAndWalk(modulePath, id.name);
			const prog = findProgram(_modIdx, modulePath);
			if (prog !== null && findDecl(prog, id.name) === null) {
				// Not found locally — search all modules
				for (let si = 0; si < _modIdx.paths.length; si += 1) {
					if (_modIdx.paths[si] === modulePath) continue;
					const decl = findDecl(_modIdx.programs[si], id.name);
					if (decl !== null) {
						markAndWalk(_modIdx.paths[si], id.name);
						break;
					}
				}
			}
		}
		return;
	}

	// CallExpr — walk callee and arguments
	if (k === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		walkBody(cd.callee, modulePath, importMap);
		for (const arg of cd.arguments) {
			walkBody(arg, modulePath, importMap);
		}
		return;
	}

	// MemberExpr — walk object + mark resolved extension/class method
	if (k === NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		walkBody(md.object, modulePath, importMap);
		if (node.resolvedSym !== null) {
			const sym2 = node.resolvedSym;
			const targetName2 = (sym2.originalName !== "" && sym2.originalName !== null) ? sym2.originalName : sym2.name;
			if (sym2.modulePath !== "" && sym2.modulePath !== modulePath) {
				markAndWalk(sym2.modulePath, targetName2);
			} else {
				markAndWalk(modulePath, targetName2);
			}
		} else if (md.property !== "") {
			// No resolvedSym (generic instantiation clears it).
			// Search all modules for the method — extension methods may be cross-module.
			for (let si = 0; si < _modIdx.paths.length; si += 1) {
				const decl = findDecl(_modIdx.programs[si], md.property);
				if (decl !== null) {
					markAndWalk(_modIdx.paths[si], md.property);
					break;
				}
			}
		}
		return;
	}

	// For all other nodes: walk children generically via forEachChild
	// NOTE: forEachChild uses a callback — we pass module-level state
	// instead of closure-captured value-type arrays to avoid use-after-free
	walkChildrenGeneric(node, modulePath, importMap);
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

	// Find ALL declarations with this name (handles overloaded functions)
	const program = findProgram(_modIdx, modulePath);
	if (program === null) return;
	const importMap = getImportMap(program, modulePath);
	const d = program.data as ProgramData;
	for (const stmt of d.programStmts) {
		if (stmt === null) continue;
		const found = matchDeclName(stmt, name);
		if (found !== null) {
			walkBody(found, modulePath, importMap);
		}
	}
}

// Find a top-level declaration by name in a program AST (first match only).
// Used by the no-resolvedSym fallback search — markAndWalk uses inline loop for all overloads.
function findDecl(program: Node, name: string): Node {
	const d = program.data as ProgramData;
	for (const stmt of d.programStmts) {
		if (stmt === null) continue;
		const found = matchDeclName(stmt, name);
		if (found !== null) return found;
	}
	return null as unknown as Node;
}

// Check if a statement is a declaration with the given name. Returns the node to walk.
function matchDeclName(node: Node, name: string): Node {
	if (node === null) return null as unknown as Node;
	const k = node.kind;

	if (k === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		if (d.fnName === name) return node;
		return null as unknown as Node;
	}
	if (k === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (d.declName === name) return node;
		return null as unknown as Node;
	}
	if (k === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		if (d.className === name) return node;
		return null as unknown as Node;
	}
	if (k === NodeKind.ActorDecl) {
		const d = node.data as ActorDeclData;
		if (d.actorName === name) return node;
		return null as unknown as Node;
	}
	if (k === NodeKind.InterfaceDecl || k === NodeKind.StructDecl) {
		const d = node.data as { interfaceName: string, interfaceFields: string[], interfaceFieldTypes: string[] };
		if (d.interfaceName === name) return node;
		return null as unknown as Node;
	}
	if (k === NodeKind.EnumDecl) {
		const d = node.data as { enumName: string, enumMembers: string[] };
		if (d.enumName === name) return node;
		return null as unknown as Node;
	}
	if (k === NodeKind.TypeAliasDecl) {
		const d = node.data as { aliasName: string, aliasType: string, aliasIsDistinct: boolean };
		if (d.aliasName === name) return node;
		return null as unknown as Node;
	}
	if (k === NodeKind.ExternDecl) {
		const d = node.data as ExternDeclData;
		if (d.externName === name) return node;
		return null as unknown as Node;
	}
	// Unwrap ExportDecl
	if (k === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return matchDeclName(d.exportedDecl, name);
	}
	// Unwrap DecoratedDecl
	if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return matchDeclName(d.decoratedNode, name);
	}
	return null as unknown as Node;
}

function findImport(importMap: ImportMap, name: string): number {
	for (let i = 0; i < importMap.names.length; i += 1) {
		if (importMap.names[i] === name) return i;
	}
	return -1;
}

// ===== Public API =====

export function computeAliveSet(programs: Node[], paths: string[], entryPath: string, isTest: boolean): AliveSet {
	// Initialize module-level state
	_aliveSet = createAliveSet();
	_modIdx = { paths, programs };
	_visitedSet = new Set<string>();
	_importCacheKeys = [];
	_importCacheVals = [];
	_progCacheKeys = [];
	_progCacheVals = [];

	// For each module, find roots and mark them alive
	for (let m = 0; m < programs.length; m += 1) {
		const modulePath = paths[m];
		const program = programs[m];
		if (program === null) continue;
		const d = program.data as ProgramData;
		const importMap = buildImportMap(program, _modIdx);

		for (const stmt of d.programStmts) {
			if (stmt === null) continue;

			// Root 1: main() in entry module
			if (modulePath === entryPath && stmt.kind === NodeKind.FunctionDecl) {
				const fd = stmt.data as FunctionDeclData;
				if (fd.fnName === "main") {
					markAndWalk(modulePath, "main");
					continue;
				}
			}
			// Also check exported main under ExportDecl
			if (modulePath === entryPath && stmt.kind === NodeKind.ExportDecl) {
				const ed = stmt.data as ExportDeclData;
				if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.FunctionDecl) {
					const fd = ed.exportedDecl.data as FunctionDeclData;
					if (fd.fnName === "main") {
						markAndWalk(modulePath, "main");
						continue;
					}
				}
			}

			// Root 2: Compiler-generated functions — always alive.
			// Must match isDeclAlive exemptions in codegen/c/declarations.ms exactly:
			// $prefix (lambda lifting), =prefix (operators), __prefix (builtinLower),
			// DRC lifecycle suffixes, generic instantiations (__ in middle of name).
			if (stmt.kind === NodeKind.FunctionDecl) {
				const fd2 = stmt.data as FunctionDeclData;
				const fn = fd2.fnName;
				if (fn.length > 0 && (fn.slice(0, 1) === "$" || fn.slice(0, 1) === "=")) {
					walkBody(stmt, modulePath, importMap);
					continue;
				}
				if (fn.length > 1 && fn.slice(0, 2) === "__") {
					walkBody(stmt, modulePath, importMap);
					continue;
				}
				// Generic instantiations: name contains __ after position 0 (e.g., hash__number)
				if (fn.indexOf("__", 0) > 0) {
					markAndWalk(modulePath, fn);
					walkBody(stmt, modulePath, importMap);
					continue;
				}
			}

			// Root 3: TestDecl nodes — in test mode (all modules) or entry module (build mode).
			// Entry module test blocks are wrapped in main() by codegen, so they're always roots.
			if (stmt.kind === NodeKind.TestDecl && (isTest || modulePath === entryPath)) {
				walkBody(stmt, modulePath, importMap);
				continue;
			}

			// Root 4: Top-level statements (side-effecting init code in Init000).
			// Unwrap ExportDecl — `export const argv = buildArgv()` is an ExportDecl
			// wrapping a VariableDecl. The inner VariableDecl is side-effecting (init code).
			let initStmt = stmt;
			if (stmt.kind === NodeKind.ExportDecl) {
				const ed = stmt.data as ExportDeclData;
				if (ed.exportedDecl !== null) initStmt = ed.exportedDecl;
			}
			if (isTopLevelStatement(initStmt)) {
				walkBody(stmt, modulePath, importMap);
				continue;
			}

			// Root 5: Exported declarations in ENTRY MODULE only.
			// Dependency module exports are NOT roots (reference parity: only sfExportc/sfCompilerProc).
			// They become alive through transitive tracing from main() or top-level statements.
			if (modulePath === entryPath && isExportedDecl(stmt)) {
				const name = getDeclName(stmt);
				if (name !== "") {
					markAndWalk(modulePath, name);
				}
			}
		}
	}

	const result = _aliveSet;
	// Clear module-level state
	_aliveSet = createAliveSet();
	_modIdx = { paths: [], programs: [] };
	_visitedSet = new Set<string>();
	_progCacheKeys = [];
	_progCacheVals = [];
	return result;
}

// Check if a statement is a side-effecting top-level statement (not a declaration)
function isTopLevelStatement(node: Node): boolean {
	const k = node.kind;
	if (k === NodeKind.ExprStmt) return true;
	if (k === NodeKind.IfStmt) return true;
	if (k === NodeKind.WhileStmt) return true;
	if (k === NodeKind.ForStmt) return true;
	if (k === NodeKind.ForOfStmt) return true;
	if (k === NodeKind.TryCatchStmt) return true;
	if (k === NodeKind.ThrowStmt) return true;
	if (k === NodeKind.BlockStmt) return true;
	if (k === NodeKind.AssertStmt) return true;
	// VariableDecl with initializer is also side-effecting
	if (k === NodeKind.VariableDecl) return true;
	return false;
}

function isExportedDecl(node: Node): boolean {
	if (node.kind === NodeKind.ExportDecl) return true;
	// DecoratedDecl wrapping an ExportDecl
	if (node.kind === NodeKind.DecoratedDecl) {
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
	assert aliveSet.entries.length === 0;
}
