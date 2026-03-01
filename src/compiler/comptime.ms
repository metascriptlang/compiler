// ComptimeEval — Evaluate @comptime blocks via Raiser VM, fold results into AST
// Runs after transforms, before analyzer/codegen.

import { test, check, testGroup } from "std/testing";
import {
	Node, NodeKind, SourceLocation, createNode,
	ComptimeBlockData, BlockStmtData, VariableDeclData,
	FunctionDeclData, ExprStmtData, ReturnStmtData,
	IfStmtData, WhileStmtData, ProgramData,
} from "../ast/node";
import { Token, TokenKind, createToken } from "../lexer/token";
import { evalASTFull } from "../codegen/raiser/eval";
import {
	RaiserValueKind, RaiserValue,
	RaiserObjectHeap, RaiserArrayHeap,
	heapArrayGet, heapArrayLen,
} from "../raiser/value";
import { RaiserContext } from "../raiser/context";

// --- Node builders (inlined to avoid import graph issues with transform/util) ---

function synthToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

function mkNumber(val: number, loc: SourceLocation): Node {
	return createNode(NodeKind.NumberLiteral, { value: val }, synthToken(loc));
}

function mkString(val: string, loc: SourceLocation): Node {
	return createNode(NodeKind.StringLiteral, { value: val }, synthToken(loc));
}

function mkBool(val: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.BooleanLiteral, { boolValue: val }, synthToken(loc));
}

function mkNull(loc: SourceLocation): Node {
	return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, synthToken(loc));
}

// --- RaiserValue → AST Node conversion ---

function valueToNode(val: RaiserValue, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, loc: SourceLocation): Node {
	if (val.kind === RaiserValueKind.Int) {
		return mkNumber(val.intVal, loc);
	} else if (val.kind === RaiserValueKind.Float) {
		return mkNumber(val.floatVal, loc);
	} else if (val.kind === RaiserValueKind.Bool) {
		return mkBool(val.intVal !== 0, loc);
	} else if (val.kind === RaiserValueKind.String) {
		return mkString(val.strVal, loc);
	} else if (val.kind === RaiserValueKind.Nil) {
		return mkNull(loc);
	} else if (val.kind === RaiserValueKind.Array) {
		const handle = val.intVal;
		const len = heapArrayLen(arrHeap, handle);
		const elements: Node[] = [];
		let i = 0;
		while (i < len) {
			const elem = heapArrayGet(arrHeap, handle, i);
			const elemNode = valueToNode(elem, objHeap, arrHeap, loc);
			elements.push(elemNode);
			i = i + 1;
		}
		return createNode(NodeKind.ArrayLiteral, { elements }, synthToken(loc));
	} else if (val.kind === RaiserValueKind.Object) {
		const handle = val.intVal;
		const obj = objHeap.objects[handle];
		const keys: string[] = [];
		const values: Node[] = [];
		let i = 0;
		while (i < obj.fields.length) {
			const fieldName = obj.fields[i].name;
			const fieldVal = obj.fields[i].value;
			keys.push(fieldName);
			const valNode = valueToNode(fieldVal, objHeap, arrHeap, loc);
			values.push(valNode);
			i = i + 1;
		}
		return createNode(NodeKind.ObjectLiteral, { properties: values, keys }, synthToken(loc));
	}
	return mkNull(loc);
}

// --- Evaluate a single ComptimeBlock node ---

function evalComptimeBlock(node: Node): Node {
	const d = node.data as ComptimeBlockData;
	const body = d.comptimeBody;
	const loc = node.location;

	// Extract statements from the body block
	const bodyData = body.data as BlockStmtData;
	const stmts = bodyData.statements;

	// Wrap in a synthetic Program node for the Raiser pipeline
	const program = createNode(NodeKind.Program, { programStmts: stmts }, synthToken(loc));

	// Evaluate through the Raiser VM
	const ctx = evalASTFull(program);

	// Convert VM result back to an AST literal
	return valueToNode(ctx.lastResult, ctx.objectHeap, ctx.arrayHeap, loc);
}

// --- First pass: check if AST contains any ComptimeBlock nodes ---

function hasComptimeBlock(node: Node): boolean {
	if (node.kind === NodeKind.ComptimeBlock) return true;
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		return hasComptimeBlock(d.initializer);
	} else if (node.kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		return hasComptimeBlock(d.expr);
	} else if (node.kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		return hasComptimeBlock(d.argument);
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		let i = 0;
		while (i < d.statements.length) {
			if (hasComptimeBlock(d.statements[i])) return true;
			i = i + 1;
		}
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		return hasComptimeBlock(d.fnBody);
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		let i = 0;
		while (i < d.programStmts.length) {
			if (hasComptimeBlock(d.programStmts[i])) return true;
			i = i + 1;
		}
	}
	return false;
}

// --- AST walker — find and replace ComptimeBlock nodes ---
// Uses if-else (not match) to avoid DRC workaround #24.

function walkNode(node: Node): Node {
	if (node.kind === NodeKind.ComptimeBlock) {
		return evalComptimeBlock(node);
	} else if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const newInit = walkNode(d.initializer);
		return createNode(NodeKind.VariableDecl, {
			declName: d.declName, declType: d.declType,
			initializer: newInit, declKind: d.declKind,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		const newExpr = walkNode(d.expr);
		return createNode(NodeKind.ExprStmt, { expr: newExpr }, synthToken(node.location));
	} else if (node.kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		const newArg = walkNode(d.argument);
		return createNode(NodeKind.ReturnStmt, { argument: newArg }, synthToken(node.location));
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		const newStmts: Node[] = [];
		let i = 0;
		while (i < d.statements.length) {
			newStmts.push(walkNode(d.statements[i]));
			i = i + 1;
		}
		return createNode(NodeKind.BlockStmt, { statements: newStmts }, synthToken(node.location));
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		const newBody = walkNode(d.fnBody);
		return createNode(NodeKind.FunctionDecl, {
			fnName: d.fnName, params: d.params, fnParamTypes: d.fnParamTypes,
			fnBody: newBody, fnFlags: d.fnFlags, fnReturnType: d.fnReturnType,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		const newCons = walkNode(d.consequent);
		const newAlt = walkNode(d.alternate);
		return createNode(NodeKind.IfStmt, {
			condition: d.condition, consequent: newCons, alternate: newAlt,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		const newBody = walkNode(d.whileBody);
		return createNode(NodeKind.WhileStmt, {
			whileCondition: d.whileCondition, whileBody: newBody,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		const newStmts: Node[] = [];
		let i = 0;
		while (i < d.programStmts.length) {
			newStmts.push(walkNode(d.programStmts[i]));
			i = i + 1;
		}
		return createNode(NodeKind.Program, { programStmts: newStmts }, synthToken(node.location));
	}
	return node;
}

// --- Public API ---

export function evaluateComptimeBlocks(program: Node): Node {
	if (!hasComptimeBlock(program)) return program;
	return walkNode(program);
}

// --- Tests ---

testGroup("Comptime: valueToNode", () => {
	test("int value", () => {
		const ctx = evalASTFull(createNode(NodeKind.Program, {
			programStmts: [
				createNode(NodeKind.ReturnStmt, {
					argument: createNode(NodeKind.NumberLiteral, { value: 42 }, createToken(TokenKind.Number, "42", 1)),
				}, createToken(TokenKind.Return, "return", 1)),
			],
		}, createToken(TokenKind.Ident, "", 1)));
		const loc: SourceLocation = { line: 1, column: 0 };
		const result = valueToNode(ctx.lastResult, ctx.objectHeap, ctx.arrayHeap, loc);
		check(result.kind === NodeKind.NumberLiteral);
	});
});
