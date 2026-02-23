// AST Node Types - Nim-aligned discriminated union design
// Pattern: ~/projects/metascript/src/ast/node.zig

import { Token } from "../lexer/token";

// ===== Node Kind Enum =====

export enum NodeKind {
	// Literals
	NumberLiteral, StringLiteral, BooleanLiteral, NullLiteral, BigIntLiteral, RegexLiteral,
	// Identifiers
	Identifier,
	// Expressions
	BinaryExpr, UnaryExpr, UpdateExpr, CallExpr, MemberExpr, ArrayAccess,
	ObjectLiteral, ArrayLiteral, ArrowFunction, FunctionExpr, TypeAssertion,
	ConditionalExpr, SpreadExpr, NewExpr,
	TryExpr, MatchExpr, MatchCase,
	AwaitExpr, YieldExpr, MoveExpr, OutExpr,
	TypeAnnotation,
	// Patterns
	ArrayPattern, ObjectPattern, ObjectPatternProp, DestructuringDecl,
	// Statements
	VariableDecl, IfStmt, WhileStmt, ForStmt, ForOfStmt, ForInStmt, BlockStmt,
	ExprStmt, ReturnStmt, BreakStmt, ContinueStmt, FunctionDecl,
	DoWhileStmt, SwitchStmt, SwitchCase,
	UnreachableStmt, MatchStmt,
	// Declarations
	ImportDecl, ExportDecl, TypeAliasDecl, EnumDecl, InterfaceDecl,
	ClassDecl, PropertyDecl, MethodDecl, ConstructorDecl,
	// Error handling
	ThrowStmt, TryCatchStmt,
	// Decorators
	MacroInvocation, DecoratedDecl,
	// Other
	DeferStmt,
	// Extern / Macro / Quote
	ExternDecl, MacroDecl, QuoteExpr,
	// Program root
	Program,
}

// ===== Source Location =====

export interface SourceLocation {
	line: number;
	column: number;
}

// ===== Node Data (Discriminated Union) =====
// Each variant has structurally unique field names for distinct anonymous structs

export type NodeData =
	// Literal variants
	| { value: number }                                            // NumberLiteral
	| { value: string }                                            // StringLiteral
	| { boolValue: boolean }                                       // BooleanLiteral
	| { nullPlaceholder: boolean }                                 // NullLiteral (always true)
	| { bigintValue: string }                                      // BigIntLiteral ("123n")
	| { regexPattern: string }                                     // RegexLiteral ("/pattern/flags")
	// Identifier
	| { name: string }                                             // Identifier
	// Expression variants
	| { operator: string, left: Node, right: Node }                // BinaryExpr
	| { unaryOp: string, operand: Node }                           // UnaryExpr
	| { updateOp: string, updateArg: Node, isPrefix: boolean }     // UpdateExpr (i++, ++i)
	| { callee: Node, arguments: Node[] }                          // CallExpr
	| { object: Node, property: string }                           // MemberExpr
	| { array: Node, index: Node }                                 // ArrayAccess
	| { properties: Node[], keys: string[] }                       // ObjectLiteral
	| { elements: Node[] }                                         // ArrayLiteral
	| { arrowParams: string[], arrowBody: Node, arrowFlags: string } // ArrowFunction
	| { funcExprParams: string[], funcExprBody: Node, funcExprFlags: string } // FunctionExpr
	| { asExpr: Node }                                             // TypeAssertion
	| { ternaryCondition: Node, ternaryConsequent: Node, ternaryAlternate: Node } // ConditionalExpr
	| { spreadArg: Node }                                          // SpreadExpr
	| { newCallee: Node, newArguments: Node[] }                    // NewExpr
	| { tryArg: Node, hasCatch: boolean, catchVal: Node }          // TryExpr
	| { matchDisc: Node, matchCases: Node[] }                      // MatchExpr
	| { casePatterns: Node[], caseBody: Node }                     // MatchCase
	| { awaitArg: Node }                                           // AwaitExpr
	| { yieldArg: Node, isDelegate: boolean }                      // YieldExpr
	| { moveArg: Node }                                            // MoveExpr
	| { outArg: Node }                                             // OutExpr
	| { annotationType: string }                                   // TypeAnnotation
	// Pattern variants
	| { patternElements: Node[], hasRestElement: boolean }         // ArrayPattern
	| { patternProps: Node[], hasRestProp: boolean }               // ObjectPattern
	| { propKey: string, propAlias: Node }                         // ObjectPatternProp
	| { destrPattern: Node, destrInit: Node, destrIsConst: boolean } // DestructuringDecl
	// Statement variants
	| { declName: string, initializer: Node, isConst: boolean }    // VariableDecl
	| { condition: Node, consequent: Node, alternate: Node }       // IfStmt
	| { whileCondition: Node, whileBody: Node }                    // WhileStmt
	| { forInit: Node, forCondition: Node, forUpdate: Node, forBody: Node } // ForStmt
	| { forOfBinding: string, forOfIsConst: boolean, forOfIterable: Node, forOfBody: Node } // ForOfStmt
	| { forInBinding: string, forInIsConst: boolean, forInObject: Node, forInBody: Node } // ForInStmt
	| { statements: Node[] }                                       // BlockStmt
	| { expr: Node }                                               // ExprStmt
	| { argument: Node }                                           // ReturnStmt
	| { breakLabel: string }                                       // BreakStmt
	| { continueLabel: string }                                    // ContinueStmt
	| { fnName: string, params: string[], fnBody: Node, fnFlags: string } // FunctionDecl
	| { doBody: Node, doCondition: Node }                          // DoWhileStmt
	| { switchDisc: Node, switchCases: Node[] }                    // SwitchStmt
	| { caseTests: Node[], caseStmts: Node[], isDefault: boolean } // SwitchCase
	| { unreachableMsg: string }                                   // UnreachableStmt
	| { matchStmtDisc: Node, matchStmtCases: Node[] }              // MatchStmt
	// Declaration variants
	| { importNames: string[], importAliases: string[], importSource: string }  // ImportDecl
	| { exportedDecl: Node }                                       // ExportDecl
	| { aliasName: string, aliasIsDistinct: boolean }               // TypeAliasDecl
	| { enumName: string, enumMembers: string[] }                  // EnumDecl
	| { interfaceName: string, interfaceFields: string[] }         // InterfaceDecl
	| { className: string, classExtends: string, classBody: Node[] } // ClassDecl
	| { propName: string, propIsStatic: boolean }                 // PropertyDecl
	| { methodName: string, methodParams: string[], methodBody: Node, methodIsStatic: boolean, methodFlags: string } // MethodDecl
	| { ctorParams: string[], ctorBody: Node }                     // ConstructorDecl
	// Error handling variants
	| { throwArg: Node }                                           // ThrowStmt
	| { tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node } // TryCatchStmt
	// Decorator variants
	| { macroName: string, macroArgs: Node[] }                     // MacroInvocation
	| { decorators: Node[], decoratedNode: Node }                  // DecoratedDecl
	| { deferExpr: Node }                                          // DeferStmt
	// Extern / Macro / Quote variants
	| { externKind: string, externName: string }                    // ExternDecl
	| { macroDeclName: string, macroDeclParams: string[], macroDeclBody: Node } // MacroDecl
	| { quoteBody: Node }                                          // QuoteExpr
	// Program root
	| { programStmts: Node[] }                                     // Program

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
