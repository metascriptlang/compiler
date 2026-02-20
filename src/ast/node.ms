// AST Node Types - Nim-aligned discriminated union design
// Pattern: ~/projects/metascript/src/ast/node.zig

import { Token } from "../lexer/token";

// ===== Node Kind Enum =====

export enum NodeKind {
	// Expressions
	NumberLiteral, StringLiteral, Identifier,
	BinaryExpr, UnaryExpr, CallExpr, MemberExpr, ArrayAccess,
	ObjectLiteral, ArrayLiteral,
	// Statements
	VariableDecl, IfStmt, WhileStmt, ForStmt, ForOfStmt, BlockStmt,
	ExprStmt, ReturnStmt, BreakStmt, ContinueStmt, FunctionDecl,
}

// ===== Source Location =====

export interface SourceLocation {
	line: number;
	column: number;
}

// ===== Node Data (Discriminated Union) =====
// Each variant has structurally unique field names for distinct anonymous structs

export type NodeData =
	// Expression variants
	| { value: number }                                            // NumberLiteral
	| { value: string }                                            // StringLiteral
	| { name: string }                                             // Identifier
	| { operator: string, left: Node, right: Node }                // BinaryExpr
	| { unaryOp: string, operand: Node }                           // UnaryExpr
	| { callee: Node, arguments: Node[] }                          // CallExpr
	| { object: Node, property: string }                           // MemberExpr
	| { array: Node, index: Node }                                 // ArrayAccess
	| { properties: Node[], keys: string[] }                       // ObjectLiteral
	| { elements: Node[] }                                         // ArrayLiteral
	// Statement variants
	| { declName: string, initializer: Node, isConst: boolean }    // VariableDecl
	| { condition: Node, consequent: Node, alternate: Node }       // IfStmt
	| { whileCondition: Node, whileBody: Node }                    // WhileStmt
	| { forInit: Node, forCondition: Node, forUpdate: Node, forBody: Node } // ForStmt
	| { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Node, forOfBody: Node } // ForOfStmt
	| { statements: Node[] }                                       // BlockStmt
	| { expr: Node }                                               // ExprStmt
	| { argument: Node }                                           // ReturnStmt
	| { breakLabel: string }                                       // BreakStmt
	| { continueLabel: string }                                    // ContinueStmt
	| { fnName: string, params: string[], fnBody: Node }           // FunctionDecl

// ===== Node Interface =====

export interface Node {
	kind: NodeKind;
	location: SourceLocation;
	data: NodeData;
	nodeType?: unknown;
}

export type Expression = Node;

// ===== Node Constructor =====

export function createNode(kind: NodeKind, data: NodeData, token: Token): Node {
	return {
		kind,
		data,
		location: { line: token.line, column: token.column },
	};
}
