// Cursor Inference — pre-pass to detect borrowed local variables
//
// A "cursor" is a local variable that only borrows from another value:
// it never escapes (not passed to calls, not returned, not stored).
// Cursors skip ALL RC ops (no incref on init, no destroy at scope exit).
//
// Matches the standard reference implementation (simplified: no union-find, linear scan).
//
// Safety: conservative — false negatives are fine (treated as owned),
// false positives would be unsound (dangling pointer).

import {
	Node, NodeKind,
	VariableDeclData, IdentifierData, MemberExprData, ArrayAccessData,
	BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData,
	WhileStmtData, ForStmtData, DoWhileStmtData,
	TryCatchStmtData, CallExprData, BinaryExprData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	ThrowStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	MoveExprData, SpreadExprData, NewExprData,
	ExportDeclData,
	ProgramData,
	DeclKind,
} from "../ast/node";
import { parseInput } from "../transform/testUtil";

// ===== Cursor Set =====

export type CursorSet = string[];

export function createCursorSet(): CursorSet {
	return [];
}

export function isCursorVar(cs: CursorSet, varName: string): boolean {
	for (const n of cs) {
		if (n === varName) return true;
	}
	return false;
}

function addCursor(cs: CursorSet, varName: string): void {
	cs.push(varName);
}

// ===== Escape Analysis =====
// Checks if a variable name appears in an "escaping" context anywhere in a subtree.
// Escaping contexts: call argument, return, throw, assignment RHS, object/array literal element,
// new expression argument, spread, move.

function varEscapesInExpr(node: Node, varName: string): boolean {
	if (node === null) return false;

	return match (node.kind) {
		NodeKind.Identifier => false,  // mere read is not escape
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			// Check if varName appears as any argument
			let escapes = false;
			for (const arg of d.arguments) {
				if (arg !== null && arg.kind === NodeKind.Identifier) {
					if ((arg.data as IdentifierData).name === varName) {
						escapes = true;
					}
				}
				// Check nested expressions in args
				if (varEscapesInExpr(arg, varName)) {
					escapes = true;
				}
			}
			// Also check callee for escaping (unlikely but thorough)
			if (varEscapesInExpr(d.callee, varName)) {
				escapes = true;
			}
			return escapes;
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			let escapes = false;
			for (const arg of d.newArguments) {
				if (arg !== null && arg.kind === NodeKind.Identifier) {
					if ((arg.data as IdentifierData).name === varName) {
						escapes = true;
					}
				}
				if (varEscapesInExpr(arg, varName)) {
					escapes = true;
				}
			}
			return escapes;
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (const prop of d.properties) {
				if (prop !== null && prop.kind === NodeKind.Identifier) {
					if ((prop.data as IdentifierData).name === varName) return true;
				}
				if (varEscapesInExpr(prop, varName)) return true;
			}
			return false;
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			for (const elem of d.elements) {
				if (elem !== null && elem.kind === NodeKind.Identifier) {
					if ((elem.data as IdentifierData).name === varName) return true;
				}
				if (varEscapesInExpr(elem, varName)) return true;
			}
			return false;
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			if (d.spreadArg.kind === NodeKind.Identifier) {
				return (d.spreadArg.data as IdentifierData).name === varName;
			} else {
				return varEscapesInExpr(d.spreadArg, varName);
			}
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			if (d.moveArg.kind === NodeKind.Identifier) {
				return (d.moveArg.data as IdentifierData).name === varName;
			} else {
				return varEscapesInExpr(d.moveArg, varName);
			}
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			// Assignment RHS: escapes if varName is on the RHS of = or compound assign
			if (d.operator === "=") {
				if (d.right.kind === NodeKind.Identifier) {
					if ((d.right.data as IdentifierData).name === varName) return true;
				}
				return varEscapesInExpr(d.right, varName);
			}
			return varEscapesInExpr(d.left, varName) || varEscapesInExpr(d.right, varName);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			return varEscapesInExpr(d.ternaryCondition, varName)
				|| varEscapesInExpr(d.ternaryConsequent, varName)
				|| varEscapesInExpr(d.ternaryAlternate, varName);
		},
		NodeKind.MemberExpr => varEscapesInExpr((node.data as MemberExprData).object, varName),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			return varEscapesInExpr(d.array, varName) || varEscapesInExpr(d.index, varName);
		},
		// Don't look inside inner functions (they capture, but that's different scope)
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => false,
		_ => false,
	};
}

function varEscapesInStmt(node: Node, varName: string): boolean {
	if (node === null) return false;

	return match (node.kind) {
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument === null) return false;
			else if (d.argument.kind === NodeKind.Identifier) {
				return (d.argument.data as IdentifierData).name === varName;
			} else {
				return varEscapesInExpr(d.argument, varName);
			}
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			if (d.throwArg === null) return false;
			else if (d.throwArg.kind === NodeKind.Identifier) {
				return (d.throwArg.data as IdentifierData).name === varName;
			} else {
				return varEscapesInExpr(d.throwArg, varName);
			}
		},
		NodeKind.ExprStmt => varEscapesInExpr((node.data as ExprStmtData).expr, varName),
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (d.initializer === null) return false;
			else {
				// Assigning cursor to another variable: escape
				if (d.initializer.kind === NodeKind.Identifier) {
					return (d.initializer.data as IdentifierData).name === varName;
				} else {
					return varEscapesInExpr(d.initializer, varName);
				}
			}
		},
		NodeKind.BlockStmt => varEscapesInStmts((node.data as BlockStmtData).statements, varName),
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return varEscapesInExpr(d.condition, varName)
				|| varEscapesInStmt(d.consequent, varName)
				|| varEscapesInStmt(d.alternate, varName);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			return varEscapesInExpr(d.whileCondition, varName) || varEscapesInStmt(d.whileBody, varName);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			return varEscapesInStmt(d.forInit, varName) || varEscapesInExpr(d.forCondition, varName)
				|| varEscapesInStmt(d.forUpdate, varName) || varEscapesInStmt(d.forBody, varName);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			return varEscapesInStmt(d.doBody, varName) || varEscapesInExpr(d.doCondition, varName);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return varEscapesInStmt(d.tryBody, varName)
				|| varEscapesInStmt(d.catchBody, varName)
				|| varEscapesInStmt(d.finallyBody, varName);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			if (varEscapesInExpr(d.switchDisc, varName)) return true;
			for (const c of d.switchCases) {
				if (c.kind === NodeKind.SwitchCase) {
					const cd = c.data as SwitchCaseData;
					if (varEscapesInStmts(cd.caseStmts, varName)) return true;
				}
			}
			return false;
		},
		// Function declarations: don't look inside (different scope)
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => false,
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			if (d.exportedDecl !== null) return varEscapesInStmt(d.exportedDecl, varName);
			else return false;
		},
		_ => false,
	};
}

function varEscapesInStmts(stmts: Node[], varName: string): boolean {
	if (stmts === null) return false;
	for (const s of stmts) {
		if (varEscapesInStmt(s, varName)) return true;
	}
	return false;
}

// ===== Init Classification =====
// Returns true if the initializer is a "borrow" (field/element access or identifier copy).

function isBorrowInit(init: Node): boolean {
	if (init === null) return false;
	return match (init.kind) {
		NodeKind.MemberExpr | NodeKind.ArrayAccess | NodeKind.Identifier => true,
		_ => false,
	};
}

// ===== Main Entry Point =====
// Walk a function body and return the set of cursor variables.
// Called once per function, before DRC injection.

export function inferCursors(body: Node): CursorSet {
	const result = createCursorSet();
	if (body === null) return result;
	if (body.kind !== NodeKind.BlockStmt) return result;

	const stmts = (body.data as BlockStmtData).statements;
	collectCursorsInStmts(stmts, stmts, result);
	return result;
}

function collectCursorsInStmts(stmts: Node[], funcStmts: Node[], cs: CursorSet): void {
	if (stmts === null) return;
	for (const stmt of stmts) {
		collectCursorsInStmt(stmt, funcStmts, cs);
	}
}

function collectCursorsInStmt(stmt: Node, funcStmts: Node[], cs: CursorSet): void {
	if (stmt === null) return;

	match (stmt.kind) {
		NodeKind.VariableDecl => {
			const d = stmt.data as VariableDeclData;
			// Only const declarations can be cursors (not reassigned)
			if (d.declKind !== DeclKind.Const) return;
			if (d.initializer === null) return;
			// Skip DRC-generated temps ($result, $old, etc.)
			if (d.declName.startsWith("$")) return;
			// Only borrow-style initializers
			if (!isBorrowInit(d.initializer)) return;
			// Check if variable escapes anywhere in the function body
			if (!varEscapesInStmts(funcStmts, d.declName)) {
				addCursor(cs, d.declName);
			}
		},
		// Recurse into compound statements to find nested declarations
		NodeKind.BlockStmt => {
			collectCursorsInStmts((stmt.data as BlockStmtData).statements, funcStmts, cs);
		},
		NodeKind.IfStmt => {
			const d = stmt.data as IfStmtData;
			collectCursorsInStmt(d.consequent, funcStmts, cs);
			collectCursorsInStmt(d.alternate, funcStmts, cs);
		},
		NodeKind.WhileStmt => {
			collectCursorsInStmt((stmt.data as WhileStmtData).whileBody, funcStmts, cs);
		},
		NodeKind.ForStmt => {
			const d = stmt.data as ForStmtData;
			collectCursorsInStmt(d.forInit, funcStmts, cs);
			collectCursorsInStmt(d.forBody, funcStmts, cs);
		},
		NodeKind.DoWhileStmt => {
			collectCursorsInStmt((stmt.data as DoWhileStmtData).doBody, funcStmts, cs);
		},
		NodeKind.TryCatchStmt => {
			const d = stmt.data as TryCatchStmtData;
			collectCursorsInStmt(d.tryBody, funcStmts, cs);
			collectCursorsInStmt(d.catchBody, funcStmts, cs);
			collectCursorsInStmt(d.finallyBody, funcStmts, cs);
		},
		_ => {},
	};
}

// ===== Tests =====

function getStmts(input: string): Node[] {
	const result = parseInput(input);
	if (!result.ok) return [];
	const prog = result.value;
	const d = prog.data as ProgramData;
	return d.programStmts;
}

function getFuncBody(input: string): Node {
	const stmts = getStmts(input);
	if (stmts.length === 0) return null as unknown as Node;
	const stmt = stmts[0];
	if (stmt.kind === NodeKind.FunctionDecl) {
		return (stmt.data as FunctionDeclData).fnBody;
	}
	return null as unknown as Node;
}

test "local read-only borrow is cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr.length; }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

test "returned variable is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; return x; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "call argument is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; process(x); }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "assigned to another var is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const y = x; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "let variable is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { let x = arr[0]; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "call result is not cursor" {
	const body = getFuncBody("function f() { const x = getValue(); }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "member access with only read use is cursor" {
	const body = getFuncBody("function f(obj: any) { const name = obj.name; if (name) {} }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "name");
}

test "thrown variable is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; throw x; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "stored in object is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const obj = { val: x }; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "DRC temp is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { const $result = arr[0]; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "$result");
}

test "nested block cursor" {
	const body = getFuncBody("function f(obj: any) { if (true) { const x = obj.name; } }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}
