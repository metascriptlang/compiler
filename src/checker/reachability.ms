// Global Dead Code Elimination — Reachability Analysis
//
// Computes an AliveSet of "modulePath:symbolName" keys by walking ASTs
// starting from roots (main, top-level stmts, test decls, exported symbols).
// Cross-module references traced via ImportDecl source paths.

import { Node, NodeKind, ProgramData, FunctionDeclData, ImportDeclData,
	ExportDeclData, IdentifierData,
	CallExprData, MemberExprData,
	TestDeclData, DecoratedDeclData, ExternDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { AliveSet, createAliveSet, aliveSetAdd, aliveSetHas } from "../codegen/c/context";

// ===== Module Index =====
// Maps module path to its program AST for cross-module tracing.

interface ModuleIndex {
	paths: string[];
	programs: Node[];
}

function findProgram(idx: ModuleIndex, path: string): Node {
	for (let i = 0; i < idx.paths.length; i += 1) {
		if (idx.paths[i] === path) return idx.programs[i];
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
			// Resolve the import specifier to a module path
			// The specifier might be relative or std/ — we match against known module paths
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



// ===== Visited Set =====

function visitedHas(visited: string[], key: string): boolean {
	for (let i = 0; i < visited.length; i += 1) {
		if (visited[i] === key) return true;
	}
	return false;
}

// ===== Core Walker =====

// Walk a node recursively, marking any referenced declarations alive.
function walkBody(node: Node, modulePath: string, aliveSet: AliveSet,
	modIdx: ModuleIndex, visited: string[], importMap: ImportMap): void {
	if (node === null) return;
	const k = node.kind;

	// Identifier with resolvedSym — mark its declaration alive
	if (k === NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym !== null) {
			// Check if this identifier refers to an imported symbol
			const id = node.data as IdentifierData;
			const importIdx = findImport(importMap, id.name);
			if (importIdx >= 0) {
				// Cross-module reference — mark in source module and walk its body
				const srcPath = importMap.sourcePaths[importIdx];
				markAndWalk(srcPath, id.name, aliveSet, modIdx, visited);
			} else {
				// Local reference
				markAndWalk(modulePath, sym.name, aliveSet, modIdx, visited);
			}
		}
		return;
	}

	// CallExpr — walk callee and arguments
	if (k === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		walkBody(cd.callee, modulePath, aliveSet, modIdx, visited, importMap);
		for (const arg of cd.arguments) {
			walkBody(arg, modulePath, aliveSet, modIdx, visited, importMap);
		}
		return;
	}

	// MemberExpr — walk object
	if (k === NodeKind.MemberExpr) {
		const md = node.data as MemberExprData;
		walkBody(md.object, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}

	// For all other nodes: walk children generically via known data shapes
	walkChildrenGeneric(node, modulePath, aliveSet, modIdx, visited, importMap);
}

// Walk all children of a node generically via shared forEachChild
function walkChildrenGeneric(node: Node, modulePath: string, aliveSet: AliveSet,
	modIdx: ModuleIndex, visited: string[], importMap: ImportMap): void {
	forEachChild(node, (child: Node): void => {
		walkBody(child, modulePath, aliveSet, modIdx, visited, importMap);
	});
}

// Mark a symbol alive and walk its body if not already visited.
function markAndWalk(modulePath: string, name: string, aliveSet: AliveSet,
	modIdx: ModuleIndex, visited: string[]): void {
	const key = modulePath + ":" + name;
	if (visitedHas(visited, key)) return;
	visited.push(key);
	aliveSetAdd(aliveSet, modulePath, name);

	// Find the declaration in the module's AST and walk its body
	const program = findProgram(modIdx, modulePath);
	if (program === null) return;
	const decl = findDecl(program, name);
	if (decl === null) return;

	// Build import map for cross-module tracing
	const importMap = buildImportMap(program, modIdx);
	walkBody(decl, modulePath, aliveSet, modIdx, visited, importMap);
}

// Find a top-level declaration by name in a program AST.
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
	if (k === NodeKind.InterfaceDecl) {
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
	const aliveSet = createAliveSet();
	const modIdx: ModuleIndex = { paths, programs };

	// For each module, find roots and mark them alive
	for (let m = 0; m < programs.length; m += 1) {
		const modulePath = paths[m];
		const program = programs[m];
		if (program === null) continue;
		const d = program.data as ProgramData;
		const importMap = buildImportMap(program, modIdx);
		const visited: string[] = [];

		for (const stmt of d.programStmts) {
			if (stmt === null) continue;

			// Root 1: main() in entry module
			if (modulePath === entryPath && stmt.kind === NodeKind.FunctionDecl) {
				const fd = stmt.data as FunctionDeclData;
				if (fd.fnName === "main") {
					markAndWalk(modulePath, "main", aliveSet, modIdx, visited);
					continue;
				}
			}
			// Also check exported main under ExportDecl
			if (modulePath === entryPath && stmt.kind === NodeKind.ExportDecl) {
				const ed = stmt.data as ExportDeclData;
				if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.FunctionDecl) {
					const fd = ed.exportedDecl.data as FunctionDeclData;
					if (fd.fnName === "main") {
						markAndWalk(modulePath, "main", aliveSet, modIdx, visited);
						continue;
					}
				}
			}

			// Root 2: TestDecl nodes (test mode only)
			if (isTest && stmt.kind === NodeKind.TestDecl) {
				walkBody(stmt, modulePath, aliveSet, modIdx, visited, importMap);
				continue;
			}

			// Root 3: Top-level statements (side-effecting init code in Init000)
			// Excludes declarations — only expression statements, variable inits, etc.
			if (isTopLevelStatement(stmt)) {
				walkBody(stmt, modulePath, aliveSet, modIdx, visited, importMap);
				continue;
			}

			// Root 4: Exported declarations (reachable from outside)
			if (isExportedDecl(stmt)) {
				const name = getDeclName(stmt);
				if (name !== "") {
					markAndWalk(modulePath, name, aliveSet, modIdx, visited);
				}
			}
		}
	}

	return aliveSet;
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

function getDeclName(node: Node): string {
	if (node === null) return "";
	const k = node.kind;
	if (k === NodeKind.FunctionDecl) { const d = node.data as FunctionDeclData; return d.fnName; }
	if (k === NodeKind.VariableDecl) { const d = node.data as VariableDeclData; return d.declName; }
	if (k === NodeKind.ClassDecl) { const d = node.data as ClassDeclData; return d.className; }
	if (k === NodeKind.InterfaceDecl) { const d = node.data as { interfaceName: string }; return d.interfaceName; }
	if (k === NodeKind.EnumDecl) { const d = node.data as { enumName: string }; return d.enumName; }
	if (k === NodeKind.TypeAliasDecl) { const d = node.data as { aliasName: string }; return d.aliasName; }
	if (k === NodeKind.ExternDecl) { const d = node.data as ExternDeclData; return d.externName; }
	if (k === NodeKind.ExportDecl) { const d = node.data as ExportDeclData; return getDeclName(d.exportedDecl); }
	if (k === NodeKind.DecoratedDecl) { const d = node.data as DecoratedDeclData; return getDeclName(d.decoratedNode); }
	return "";
}

// ===== Tests =====

import { createNode } from "../ast/node";

test "endsWith helper" {
	assert "foo/bar.ms".endsWith("bar.ms");
	assert "foo/bar.ms".endsWith("foo/bar.ms");
	assert !"foo/bar.ms".endsWith("baz.ms");
}

test "empty programs produce empty alive set" {
	const aliveSet = computeAliveSet([], [], "/entry.ms", false);
	assert aliveSet.entries.length === 0;
}
