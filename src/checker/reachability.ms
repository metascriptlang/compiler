// Global Dead Code Elimination — Reachability Analysis
//
// Computes an AliveSet of "modulePath:symbolName" keys by walking ASTs
// starting from roots (main, top-level stmts, test decls, exported symbols).
// Cross-module references traced via ImportDecl source paths.

import { Node, NodeKind, ProgramData, FunctionDeclData, ImportDeclData,
	VariableDeclData, ExportDeclData, ExprStmtData, IdentifierData,
	CallExprData, MemberExprData, ClassDeclData,
	TestDeclData, DecoratedDeclData, ExternDeclData, BlockStmtData,
	MethodDeclData, ConstructorDeclData } from "../ast/node";
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
		if (endsWith(p, specifier) || endsWith(p, specifier + ".ms") || endsWith(p, specifier + ".cms") || endsWith(p, specifier + "/index.ms") || endsWith(p, specifier + "/index.cms")) {
			return p;
		}
	}
	return "";
}

function endsWith(s: string, suffix: string): boolean {
	if (suffix.length > s.length) return false;
	return s.slice(s.length - suffix.length, s.length) === suffix;
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

// Walk all children of a node generically
function walkChildrenGeneric(node: Node, modulePath: string, aliveSet: AliveSet,
	modIdx: ModuleIndex, visited: string[], importMap: ImportMap): void {
	const k = node.kind;

	if (k === NodeKind.Program) {
		const d = node.data as ProgramData;
		for (const s of d.programStmts) walkBody(s, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const s of d.statements) walkBody(s, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		walkBody(d.fnBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		walkBody(d.initializer, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		walkBody(d.expr, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		walkBody(d.exportedDecl, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		walkBody(d.decoratedNode, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.TestDecl) {
		const d = node.data as TestDeclData;
		walkBody(d.testBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ReturnStmt) {
		const d = node.data as { argument: Node };
		walkBody(d.argument, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.IfStmt) {
		const d = node.data as { condition: Node, consequent: Node, alternate: Node };
		walkBody(d.condition, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.consequent, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.alternate, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.WhileStmt) {
		const d = node.data as { whileCondition: Node, whileBody: Node };
		walkBody(d.whileCondition, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.whileBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ForStmt) {
		const d = node.data as { forInit: Node, forCondition: Node, forUpdate: Node, forBody: Node };
		walkBody(d.forInit, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.forCondition, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.forUpdate, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.forBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ForOfStmt) {
		const d = node.data as { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Node, forOfBody: Node };
		walkBody(d.forOfIterable, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.forOfBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.DoWhileStmt) {
		const d = node.data as { doBody: Node, doCondition: Node };
		walkBody(d.doBody, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.doCondition, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.TryCatchStmt) {
		const d = node.data as { tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node };
		walkBody(d.tryBody, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.catchBody, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.finallyBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ThrowStmt) {
		const d = node.data as { throwArg: Node };
		walkBody(d.throwArg, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.BinaryExpr) {
		const d = node.data as { operator: string, left: Node, right: Node };
		walkBody(d.left, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.right, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.UnaryExpr) {
		const d = node.data as { unaryOp: string, operand: Node };
		walkBody(d.operand, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ConditionalExpr) {
		const d = node.data as { ternaryCondition: Node, ternaryConsequent: Node, ternaryAlternate: Node };
		walkBody(d.ternaryCondition, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.ternaryConsequent, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.ternaryAlternate, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ArrayLiteral) {
		const d = node.data as { elements: Node[] };
		for (const e of d.elements) walkBody(e, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ObjectLiteral) {
		const d = node.data as { properties: Node[], keys: string[] };
		for (const p of d.properties) walkBody(p, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ArrayAccess) {
		const d = node.data as { array: Node, index: Node };
		walkBody(d.array, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.index, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.UpdateExpr) {
		const d = node.data as { updateOp: string, updateArg: Node, isPrefix: boolean };
		walkBody(d.updateArg, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.SpreadExpr) {
		const d = node.data as { spreadArg: Node };
		walkBody(d.spreadArg, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.NewExpr) {
		const d = node.data as { newCallee: Node, newArguments: Node[] };
		walkBody(d.newCallee, modulePath, aliveSet, modIdx, visited, importMap);
		for (const a of d.newArguments) walkBody(a, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.TryExpr) {
		const d = node.data as { tryArg: Node, hasCatch: boolean, catchVal: Node };
		walkBody(d.tryArg, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.catchVal, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.TypeAssertion) {
		const d = node.data as { asExpr: Node, asType: string };
		walkBody(d.asExpr, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.MatchExpr || k === NodeKind.MatchStmt) {
		if (k === NodeKind.MatchExpr) {
			const d = node.data as { matchDisc: Node, matchCases: Node[] };
			walkBody(d.matchDisc, modulePath, aliveSet, modIdx, visited, importMap);
			for (const c of d.matchCases) walkBody(c, modulePath, aliveSet, modIdx, visited, importMap);
		} else {
			const d = node.data as { matchStmtDisc: Node, matchStmtCases: Node[] };
			walkBody(d.matchStmtDisc, modulePath, aliveSet, modIdx, visited, importMap);
			for (const c of d.matchStmtCases) walkBody(c, modulePath, aliveSet, modIdx, visited, importMap);
		}
		return;
	}
	if (k === NodeKind.MatchCase) {
		const d = node.data as { casePatterns: Node[], caseBody: Node };
		for (const p of d.casePatterns) walkBody(p, modulePath, aliveSet, modIdx, visited, importMap);
		walkBody(d.caseBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.SwitchStmt) {
		const d = node.data as { switchDisc: Node, switchCases: Node[] };
		walkBody(d.switchDisc, modulePath, aliveSet, modIdx, visited, importMap);
		for (const c of d.switchCases) walkBody(c, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.SwitchCase) {
		const d = node.data as { caseTests: Node[], caseStmts: Node[], isDefault: boolean };
		for (const t of d.caseTests) walkBody(t, modulePath, aliveSet, modIdx, visited, importMap);
		for (const s of d.caseStmts) walkBody(s, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		for (const m of d.classBody) walkBody(m, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		walkBody(d.methodBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		walkBody(d.ctorBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.AwaitExpr) {
		const d = node.data as { awaitArg: Node };
		walkBody(d.awaitArg, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.YieldExpr) {
		const d = node.data as { yieldArg: Node, isDelegate: boolean };
		walkBody(d.yieldArg, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.MoveExpr) {
		const d = node.data as { moveArg: Node };
		walkBody(d.moveArg, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.OutExpr) {
		const d = node.data as { outArg: Node };
		walkBody(d.outArg, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.HiddenDeref || k === NodeKind.HiddenAddr) {
		const d = node.data as { convExpr: Node, convType: Type };
		walkBody(d.convExpr, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.HiddenStdConv || k === NodeKind.HiddenSubConv) {
		const d = node.data as { convExpr: Node, convType: Type };
		walkBody(d.convExpr, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ArrowFunction) {
		const d = node.data as { arrowParams: string[], arrowParamTypes: string[], arrowBody: Node, arrowFlags: string, arrowReturnType: string };
		walkBody(d.arrowBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.FunctionExpr) {
		const d = node.data as { funcExprParams: string[], funcExprParamTypes: string[], funcExprBody: Node, funcExprFlags: string, funcExprReturnType: string };
		walkBody(d.funcExprBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.DeferStmt) {
		const d = node.data as { deferExpr: Node };
		walkBody(d.deferExpr, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	if (k === NodeKind.ComptimeBlock) {
		const d = node.data as { comptimeBody: Node };
		walkBody(d.comptimeBody, modulePath, aliveSet, modIdx, visited, importMap);
		return;
	}
	// Leaves (literals, break, continue, import, type annotations, etc.) — no children to walk
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
	expect(endsWith("foo/bar.ms", "bar.ms"));
	expect(endsWith("foo/bar.ms", "foo/bar.ms"));
	expect(!endsWith("foo/bar.ms", "baz.ms"));
}

test "empty programs produce empty alive set" {
	const aliveSet = computeAliveSet([], [], "/entry.ms", false);
	expect(aliveSet.entries.length === 0);
}
