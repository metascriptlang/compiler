// Trans-Am Hash Utilities — djb2 string hashing, hash combinators, AST content hashing
//
// The engine decides validity by change revisions, never by these hashes; the build
// session fingerprints generic instances with them (buildSession.ms).
//
// transAmHashNode hashes kind + data fields recursively, skipping positions/comments/types/symbols.

import {
	Node, NodeKind, NodeFlag,
	NumberLiteralData, StringLiteralData, BooleanLiteralData, RegexLiteralData, BigIntLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData,
	MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData,
	ArrowFunctionData, FunctionExprData, TypeAssertionData, ConditionalExprData,
	SpreadExprData, NewExprData, TryExprData, MatchExprData, MatchCaseData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData,
	HiddenStdConvData, HiddenDerefData, TypeAnnotationData,
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData, DestructuringDeclData,
	VariableDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData,
	BlockStmtData, ExprStmtData, ReturnStmtData, BreakStmtData, ContinueStmtData,
	FunctionDeclData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	UnreachableStmtData, MatchStmtData,
	ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData, InterfaceDeclData,
	ClassDeclData, ActorDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ExternDeclData, MacroDeclData, DecoratedDeclData, ProgramData,
	DeferStmtData, ThrowStmtData, TryCatchStmtData,
	MacroInvocationData, TestDeclData, AssertStmtData,
	QuoteExprData, ComptimeBlockData,
	TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData,
	SpliceManyData,
	JSXElementData, JSXFragmentData, JSXTextData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData, ComputedPropertyData,
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import { forEachChild } from "../../ast/visitor";


// ===== Imports from std/hash =====

import { djb2 } from "std/hash";
export function taHashString(s: string): int64 { return djb2(s); }

// ===== Hash Combinators =====
// Uses multiplication + modulo (not bitwise ops) for JS-backend compatibility.
// Bitwise <<, >>, ^ operate on signed int32 in JS, giving different results than C int64.

const PRIME: int64 = 2147483647;

export function combine(a: int64, b: int64): int64 {
	return ((a * 31) + b) % PRIME;
}

// ===== AST Content Hash Helpers =====

export function hS(h: int64, s: string): int64 {
	if (s == null) return combine(h, 0);
	return combine(h, taHashString(s));
}

export function hI(h: int64, n: int64): int64 {
	const v = (n < 0) ? (0 - n) : n;
	return combine(h, v % PRIME);
}

export function hB(h: int64, b: boolean): int64 {
	return combine(h, b ? 1 : 0);
}

function hN(h: int64, node: Node | null): int64 {
	if (node == null) return combine(h, 0);
	return combine(h, taHashNode(node));
}

function hNodes(h: int64, nodes: Node[]): int64 {
	if (nodes == null) return combine(h, 0);
	h = hI(h, nodes.length);
	for (const node of nodes) {
		h = hN(h, node);
	}
	return h;
}

function hNodeRows(h: int64, rows: Node[][]): int64 {
	if (rows == null) return combine(h, 0);
	h = hI(h, rows.length);
	for (const row of rows) {
		h = hNodes(h, row);
	}
	return h;
}

function hStrings(h: int64, strs: string[]): int64 {
	if (strs == null) return combine(h, 0);
	h = hI(h, strs.length);
	for (const s of strs) {
		h = hS(h, s);
	}
	return h;
}

function hF(h: int64, v: float64): int64 {
	return hS(h, String(v));
}

function hFloats(h: int64, nums: float64[]): int64 {
	if (nums == null) return combine(h, 0);
	h = hI(h, nums.length);
	for (const n of nums) {
		h = hF(h, n);
	}
	return h;
}

// ===== AST Content Hash =====
// Hashes node kind + data fields recursively. Skips: location, comments, nodeType, resolvedSym, checker-set flags.
// Produces identical hash for structurally identical trees regardless of position.
//
// Invariant: Node.typeExpr / typeExprs are intentionally NOT hashed. They are
// an LSP-only side channel carrying positioned type-annotation AST for
// hover/goto-def. The semantic type information lives in the string-form
// annotations INSIDE NodeData (declType, fnReturnType, interfaceFieldTypes,
// etc.) which ARE hashed via the per-variant data walk below. Hashing
// typeExpr would change the hash on trivial position shifts (newlines,
// comments) even when the semantic AST is identical. When a new type annotation affecting
// semantics is added, ensure it lives inside NodeData (not Node.typeExpr) OR
// extend this function to hash the new channel.

export function transAmHashNode(node: Node): number {
	return taHashNode(node) as number;
}

export function taHashNode(node: Node): int64 {
	return hashNode(node, true);
}

export function transAmHashSurface(node: Node): number {
	return hashNode(node, false) as number;
}

export function transAmHashLowered(node: Node): number {
	if (node == null) return 0;
	let h: int64 = taHashNode(node);
	const visit = (n: Node): void => {
		h = hI(h, n.location != null ? n.location.line : 0);
		h = hI(h, n.location != null ? n.location.column : 0);
		h = hFlags(h, n.flags);
		forEachChild(n, visit);
	};
	visit(node);
	return h as number;
}

const HASHED_NODE_FLAGS: BitSet<NodeFlag> = NodeFlag.Optional | NodeFlag.Accessor | NodeFlag.AutoAccessor | NodeFlag.ExportDefault | NodeFlag.ExternC | NodeFlag.Converter | NodeFlag.StaticStorage | NodeFlag.TypeModifier | NodeFlag.ValueUnion | NodeFlag.Parenthesized | NodeFlag.QuoteSplice | NodeFlag.WhenDeferred | NodeFlag.WhenPicked | NodeFlag.CommaWritten | NodeFlag.ExplicitDeref;

function hFlags(h: int64, flags: BitSet<NodeFlag>): int64 {
	if (flags.isEmpty()) return combine(h, 0);
	for (const flag of flags.toItems()) h = hI(h, flag as int32);
	return h;
}

function hMembers(h: int64, nodes: Node[], bodies: boolean): int64 {
	h = hI(h, nodes.length);
	for (const node of nodes) h = combine(h, hashNode(node, bodies));
	return h;
}

function hashNode(node: Node, bodies: boolean): int64 {
	if (node == null) return 0;
	let h: int64 = ((node.kind as int32 as int64) * 2654435761) % PRIME;
	h = hS(h, node.typeArg);
	h = hFlags(h, node.flags.intersection(HASHED_NODE_FLAGS));

	match (node.kind) {
		// === Literals ===
		NodeKind.NumberLiteral => {
			const nd = node.data as NumberLiteralData;
			h = hF(h, nd.value);
			if (nd.isFloat) {
				h = hI(h, 1);
			} else {
				h = hI(h, nd.intVal & 0xFFFFFFFF);
				h = hI(h, (nd.intVal >> 32) & 0xFFFFFFFF);
			}
			h = hS(h, nd.outOfRangeText); h = hB(h, nd.isBitPattern);
		},
		NodeKind.StringLiteral => {
			h = hS(h, (node.data as StringLiteralData).value);
		},
		NodeKind.BooleanLiteral => {
			h = hB(h, (node.data as BooleanLiteralData).boolValue);
		},
		NodeKind.NullLiteral => {},
		NodeKind.BigIntLiteral => {
			h = hS(h, (node.data as BigIntLiteralData).bigintValue);
		},
		NodeKind.RegexLiteral => {
			h = hS(h, (node.data as RegexLiteralData).regexPattern);
		},

		// === Identifier ===
		NodeKind.Identifier => {
			h = hS(h, (node.data as IdentifierData).name);
		},

		// === Expressions ===
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			h = hS(h, d.operator); h = hN(h, d.left); h = hN(h, d.right);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			h = hS(h, d.unaryOp); h = hN(h, d.operand);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			h = hS(h, d.updateOp); h = hN(h, d.updateArg); h = hB(h, d.isPrefix);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			h = hN(h, d.callee); h = hNodes(h, d.arguments); h = hB(h, d.isDirectCall);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			h = hN(h, d.object); h = hS(h, d.property); h = hB(h, d.isOptional);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			h = hN(h, d.array); h = hN(h, d.index);
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			h = hNodes(h, d.properties); h = hStrings(h, d.keys);
		},
		NodeKind.ArrayLiteral => {
			h = hNodes(h, (node.data as ArrayLiteralData).elements);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			h = hStrings(h, d.arrowParams); h = hStrings(h, d.arrowParamTypes);
			h = hN(h, d.arrowBody); h = hS(h, d.arrowFlags); h = hS(h, d.arrowReturnType); h = hNodes(h, d.arrowDefaults);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			h = hStrings(h, d.funcExprParams); h = hStrings(h, d.funcExprParamTypes);
			h = hN(h, d.funcExprBody); h = hS(h, d.funcExprFlags); h = hS(h, d.funcExprReturnType);
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			h = hN(h, d.asExpr); h = hS(h, d.asType);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			h = hN(h, d.ternaryCondition); h = hN(h, d.ternaryConsequent); h = hN(h, d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			h = hN(h, (node.data as SpreadExprData).spreadArg);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			h = hN(h, d.newCallee); h = hNodes(h, d.newArguments);
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			h = hN(h, d.tryArg); h = hB(h, d.hasCatch); h = hN(h, d.catchVal);
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			h = hN(h, d.matchDisc); h = hNodes(h, d.matchCases);
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			h = hNodes(h, d.casePatterns); h = hN(h, d.caseGuard); h = hN(h, d.caseBody);
		},
		NodeKind.AwaitExpr => {
			h = hN(h, (node.data as AwaitExprData).awaitArg);
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			h = hN(h, d.yieldArg); h = hB(h, d.isDelegate);
		},
		NodeKind.MoveExpr => {
			h = hN(h, (node.data as MoveExprData).moveArg);
		},
		NodeKind.OutExpr => {
			h = hN(h, (node.data as OutExprData).outArg);
		},
		NodeKind.SizeofExpr => {
			h = hS(h, (node.data as SizeofExprData).sizeofType);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			h = hN(h, (node.data as HiddenStdConvData).convExpr);
			// Skip convType — it's checker output, not parse output
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			h = hN(h, (node.data as HiddenDerefData).expr);
		},
		NodeKind.TypeAnnotation => {
			h = hS(h, (node.data as TypeAnnotationData).annotationType);
		},

		// === Patterns ===
		NodeKind.ArrayPattern => {
			const d = node.data as ArrayPatternData;
			h = hNodes(h, d.patternElements); h = hB(h, d.hasRestElement); h = hNodes(h, d.patternDefaults);
		},
		NodeKind.ObjectPattern => {
			const d = node.data as ObjectPatternData;
			h = hNodes(h, d.patternProps); h = hB(h, d.hasRestProp);
		},
		NodeKind.ObjectPatternProp => {
			const d = node.data as ObjectPatternPropData;
			h = hS(h, d.propKey); h = hN(h, d.propAlias); h = hN(h, d.propDefault);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			h = hN(h, d.destrPattern); h = hN(h, d.destrInit); h = hB(h, d.destrIsConst);
		},

		// === Statements ===
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			h = hS(h, d.declName); h = hS(h, d.declType); h = hN(h, d.initializer); h = hI(h, d.declKind as int32 as int64);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			h = hN(h, d.condition); h = hN(h, d.consequent); h = hN(h, d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			h = hN(h, d.whileCondition); h = hN(h, d.whileBody); h = hS(h, d.whileLabel);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			h = hN(h, d.forInit); h = hN(h, d.forCondition); h = hN(h, d.forUpdate); h = hN(h, d.forBody); h = hS(h, d.forLabel);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			h = hS(h, d.forOfBinding); h = hB(h, d.forOfIsConst);
			h = hN(h, d.forOfIterable); h = hN(h, d.forOfBody); h = hN(h, d.forOfPattern); h = hS(h, d.forOfLabel);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			h = hS(h, d.forInBinding); h = hB(h, d.forInIsConst);
			h = hN(h, d.forInObject); h = hN(h, d.forInBody); h = hS(h, d.forInLabel);
		},
		NodeKind.BlockStmt => {
			h = hNodes(h, (node.data as BlockStmtData).statements);
		},
		NodeKind.ExprStmt => {
			h = hN(h, (node.data as ExprStmtData).expr);
		},
		NodeKind.ReturnStmt => {
			h = hN(h, (node.data as ReturnStmtData).argument);
		},
		NodeKind.BreakStmt => {
			h = hS(h, (node.data as BreakStmtData).breakLabel);
		},
		NodeKind.ContinueStmt => {
			h = hS(h, (node.data as ContinueStmtData).continueLabel);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			h = hS(h, d.fnName); h = hStrings(h, d.params); h = hStrings(h, d.fnParamTypes);
			h = bodies ? hN(h, d.fnBody) : combine(h, 0); h = hS(h, d.fnFlags); h = hS(h, d.fnReturnType);
			h = hNodes(h, d.fnDefaults); h = hS(h, d.nativeName);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			h = hN(h, d.doBody); h = hN(h, d.doCondition); h = hS(h, d.dwLabel);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			h = hN(h, d.switchDisc); h = hNodes(h, d.switchCases);
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			h = hNodes(h, d.caseTests); h = hNodes(h, d.caseStmts); h = hB(h, d.isDefault);
		},
		NodeKind.UnreachableStmt => {
			h = hS(h, (node.data as UnreachableStmtData).unreachableMsg);
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			h = hN(h, d.matchStmtDisc); h = hNodes(h, d.matchStmtCases);
		},

		// === Declarations ===
		NodeKind.ImportDecl => {
			const d = node.data as ImportDeclData;
			h = hStrings(h, d.importNames); h = hStrings(h, d.importAliases); h = hS(h, d.importSource); h = hStrings(h, d.importTypeNames);
		},
		NodeKind.ExportDecl => {
			h = combine(h, hashNode((node.data as ExportDeclData).exportedDecl, bodies));
		},
		NodeKind.TypeAliasDecl => {
			const d = node.data as TypeAliasDeclData;
			h = hS(h, d.aliasName); h = hS(h, d.aliasType); h = hB(h, d.aliasIsDistinct); h = hS(h, d.aliasGenericParams);
			h = hS(h, d.discriminantName); h = hS(h, d.discriminantType);
			h = hStrings(h, d.variantKeys); h = hStrings(h, d.variantTypes);
		},
		NodeKind.EnumDecl => {
			const d = node.data as EnumDeclData;
			h = hS(h, d.enumName); h = hStrings(h, d.enumMembers); h = hFloats(h, d.enumValues); h = hNodes(h, d.enumInits);
		},
		NodeKind.InterfaceDecl | NodeKind.StructDecl => {
			const d = node.data as InterfaceDeclData;
			h = hS(h, d.interfaceName); h = hStrings(h, d.interfaceFields); h = hStrings(h, d.interfaceFieldTypes);
			h = hNodeRows(h, d.interfaceFieldDecorators); h = hStrings(h, d.interfaceOptionalFields); h = hS(h, d.nativeName);
			h = hStrings(h, d.interfaceExtends); h = hStrings(h, d.interfaceFieldVisibility);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			h = hS(h, d.className); h = hS(h, d.classDisplayName); h = hS(h, d.classExtends); h = hStrings(h, d.classImplements);
			h = hMembers(h, d.classBody, bodies);
		},
		NodeKind.ActorDecl => {
			const d = node.data as ActorDeclData;
			h = hS(h, d.actorName); h = hMembers(h, d.actorBody, bodies);
		},
		NodeKind.PropertyDecl => {
			const d = node.data as PropertyDeclData;
			h = hS(h, d.propName); h = hS(h, d.propType); h = hB(h, d.propIsStatic); h = hB(h, d.propIsReadonly); h = hS(h, d.propVisibility); if (d.propInitializer != null) { h = hNodes(h, [d.propInitializer]); }
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			h = hS(h, d.methodName); h = hStrings(h, d.methodParams); h = hStrings(h, d.methodParamTypes);
			h = bodies ? hN(h, d.methodBody) : combine(h, 0); h = hB(h, d.methodIsStatic);
			h = hS(h, d.methodFlags); h = hS(h, d.methodVisibility); h = hS(h, d.methodReturnType); h = hS(h, d.nativeName);
			h = hNodes(h, d.methodDefaults);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			h = hStrings(h, d.ctorParams); h = hStrings(h, d.ctorParamTypes); h = bodies ? hN(h, d.ctorBody) : combine(h, 0); h = hS(h, d.ctorVisibility);
			h = hNodes(h, d.ctorDefaults);
		},
		NodeKind.ExternDecl => {
			const d = node.data as ExternDeclData;
			h = hI(h, d.externKind as int32 as int64); h = hS(h, d.externName); h = hS(h, d.nativeName); h = hS(h, d.externType);
		},

		// === Error Handling ===
		NodeKind.ThrowStmt => {
			h = hN(h, (node.data as ThrowStmtData).throwArg);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			h = hN(h, d.tryBody); h = hS(h, d.catchName); h = hN(h, d.catchBody); h = hN(h, d.finallyBody); h = hB(h, d.hasCatchClause);
		},

		// === Decorators ===
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			h = hS(h, d.macroName); h = hNodes(h, d.macroArgs); h = hB(h, d.macroHasParens);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			h = hNodes(h, d.decorators); h = combine(h, hashNode(d.decoratedNode, bodies));
		},

		// === Other ===
		NodeKind.DeferStmt => {
			h = hN(h, (node.data as DeferStmtData).deferExpr);
		},
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			h = hS(h, d.testName); h = hN(h, d.testBody);
		},
		NodeKind.AssertStmt => {
			const d = node.data as AssertStmtData;
			h = hN(h, d.assertExpr); h = hS(h, d.assertSource); h = hS(h, d.assertMessage); h = hN(h, d.assertMessageExpr);
		},
		NodeKind.MacroDecl => {
			const d = node.data as MacroDeclData;
			h = hS(h, d.macroDeclName); h = hStrings(h, d.macroDeclParams); h = hStrings(h, d.macroDeclParamTypes); h = hS(h, d.macroDeclReturnType);
			h = bodies ? hN(h, d.macroDeclBody) : combine(h, 0);
		},
		NodeKind.QuoteExpr => {
			h = hN(h, (node.data as QuoteExprData).quoteBody);
		},
		NodeKind.ComptimeBlock => {
			h = hN(h, (node.data as ComptimeBlockData).comptimeBody);
		},

		// === Program Root ===
		NodeKind.Program => {
			h = hMembers(h, (node.data as ProgramData).programStmts, bodies);
		},

		// === SpliceMany — A2 macro multi-decl emission ===
		NodeKind.SpliceMany => {
			h = hNodes(h, (node.data as SpliceManyData).spliceNodes);
		},

		// === Type Expression Nodes ===
		NodeKind.TypeGeneric => {
			const d = node.data as TypeGenericData;
			h = hN(h, d.typExprBase); h = hNodes(h, d.typExprArgs);
		},
		NodeKind.TypeArray => {
			const d = node.data as TypeArrayData;
			h = hN(h, d.typExprElement); h = hF(h, d.typExprSize);
		},
		NodeKind.TypeUnion => {
			h = hNodes(h, (node.data as TypeUnionData).typExprMembers);
		},
		NodeKind.TypeIntersection => {
			h = hNodes(h, (node.data as TypeIntersectionData).typExprMembers);
		},
		NodeKind.TypeFunction => {
			const d = node.data as TypeFunctionData;
			h = hNodes(h, d.typExprParams); h = hN(h, d.typExprReturn); h = hStrings(h, d.typExprParamNames);
		},
		NodeKind.TypeObject => {
			const d = node.data as TypeObjectData;
			h = hStrings(h, d.typExprFieldNames); h = hNodes(h, d.typExprFieldTypes);
			h = hN(h, d.typExprIndexKey); h = hN(h, d.typExprIndexValue); h = hStrings(h, d.typExprOptionalFields);
			h = hNodeRows(h, d.typExprFieldDecorators); h = hS(h, d.typExprTypeName);
		},
		// JSX (compile-time only — but hashed for Trans-Am cache consistency)
		NodeKind.JSXElement => {
			const d = node.data as JSXElementData;
			h = hS(h, d.jsxTag); h = hNodes(h, d.jsxAttrs); h = hNodes(h, d.jsxChildren); h = hB(h, d.jsxSelfClosing);
		},
		NodeKind.JSXFragment => {
			const d = node.data as JSXFragmentData;
			h = hNodes(h, d.jsxFragChildren);
		},
		NodeKind.JSXText => {
			const d = node.data as JSXTextData;
			h = hS(h, d.jsxText);
		},
		NodeKind.JSXExpressionContainer => {
			const d = node.data as JSXExpressionContainerData;
			h = hN(h, d.jsxExpr);
		},
		NodeKind.JSXAttribute => {
			const d = node.data as JSXAttributeData;
			h = hS(h, d.jsxAttrName); h = hN(h, d.jsxAttrValue);
		},
		NodeKind.JSXSpreadAttribute => {
			const d = node.data as JSXSpreadAttributeData;
			h = hN(h, d.jsxSpreadArg);
		},
		NodeKind.ComputedProperty => {
			const d = node.data as ComputedPropertyData;
			h = hN(h, d.computedKey); h = hN(h, d.computedValue);
		},
	};

	return h;
}


// ===== Tests =====
test "empty string has known value" {
	const h = taHashString("");
	assert h == 5381;
}

test "same string same hash" { assert taHashString("hello") == taHashString("hello"); }

test "different strings different hashes" { assert taHashString("abc") != taHashString("xyz"); }

test "single char" {
	const h = taHashString("a");
	assert h != 5381;  // different from empty
	assert h != 0;
}

test "combine is deterministic" { assert combine(1, 2) == combine(1, 2); }

test "chained order matters" {
	const a = combine(combine(0, 1), 2);
	const b = combine(combine(0, 2), 1);
	assert a != b;
}

test "null node hashes to zero" {
	assert transAmHashNode(null as unknown as Node) == 0;
}

test "same AST same hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const x = 1;");
	assert r1.ok;
	assert r2.ok;
	assert transAmHashNode(r1.value) == transAmHashNode(r2.value);
}

test "comment-only change same hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const x = 1; // comment");
	assert r1.ok;
	assert r2.ok;
	assert transAmHashNode(r1.value) == transAmHashNode(r2.value);
}

test "different code different hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const x = 2;");
	assert r1.ok;
	assert r2.ok;
	assert transAmHashNode(r1.value) != transAmHashNode(r2.value);
}

test "different identifier different hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const y = 1;");
	assert r1.ok;
	assert r2.ok;
	assert transAmHashNode(r1.value) != transAmHashNode(r2.value);
}

function parseHash(source: string): number {
	const r = parseSource(source);
	if (!r.ok) throw new Error("parse failed: " + source);
	return transAmHashNode(r.value);
}

function surfaceHash(source: string): number {
	const r = parseSource(source);
	if (!r.ok) throw new Error("parse failed: " + source);
	return transAmHashSurface(r.value);
}

function loweredHash(source: string): number {
	const r = parseSource(source);
	if (!r.ok) throw new Error("parse failed: " + source);
	return transAmHashLowered(r.value);
}

test "surface hash ignores function body" {
	assert surfaceHash("export function f(a: int32): int32 { return a + 1; }")
		== surfaceHash("export function f(a: int32): int32 { return a * 2 + 7; }");
	assert parseHash("export function f(a: int32): int32 { return a + 1; }")
		!= parseHash("export function f(a: int32): int32 { return a * 2 + 7; }");
}

test "surface hash sees signature" {
	const base = surfaceHash("export function f(a: int32): int32 { return a; }");
	assert base != surfaceHash("export function f(a: int64): int32 { return a; }");
	assert base != surfaceHash("export function f(a: int32): int64 { return a; }");
	assert base != surfaceHash("export function f(a: int32, b: int32 = 2): int32 { return a; }");
}

test "surface hash masks method and constructor bodies but not fields" {
	const base = surfaceHash("export class C { x: int32; constructor(a: int32) { this.x = a; } get(): int32 { return this.x; } }");
	assert base == surfaceHash("export class C { x: int32; constructor(a: int32) { this.x = a + 1; } get(): int32 { return 0; } }");
	assert base != surfaceHash("export class C { x: int64; constructor(a: int32) { this.x = a; } get(): int32 { return this.x; } }");
	assert base != surfaceHash("export class C { x: int32; y: int32; constructor(a: int32) { this.x = a; } get(): int32 { return this.x; } }");
}

test "surface hash keeps exported initialiser" {
	assert surfaceHash("export const k = 1;") != surfaceHash("export const k = 2;");
}

test "surface hash masks bodies under decorators" {
	assert surfaceHash("@inline export function f(): int32 { return 1; }")
		== surfaceHash("@inline export function f(): int32 { return 2; }");
}

test "surface hash masks actor method bodies" {
	assert surfaceHash("actor A { ping(): int32 { return 1; } }")
		== surfaceHash("actor A { ping(): int32 { return 2; } }");
}

test "hash sees constructor default" {
	assert parseHash("class C { constructor(a: int32 = 1) {} }") != parseHash("class C { constructor(a: int32 = 2) {} }");
}

test "hash sees arrow default" {
	assert parseHash("const f = (a: int32 = 1) => a;") != parseHash("const f = (a: int32 = 2) => a;");
}

test "hash sees loop labels a transform sets" {
	const sources = ["while (true) { }", "for (let i = 0; i < 1; i++) { }", "for (const x of y) { }", "for (const k in y) { }", "do { } while (true);"];
	for (const source of sources) {
		const r = parseSource(source);
		if (!r.ok) throw new Error("parse failed: " + source);
		const stmt = (r.value.data as ProgramData).programStmts[0];
		const before = transAmHashNode(r.value);
		match (stmt.kind) {
			NodeKind.WhileStmt => { (stmt.data as WhileStmtData).whileLabel = "lp"; },
			NodeKind.ForStmt => { (stmt.data as ForStmtData).forLabel = "lp"; },
			NodeKind.ForOfStmt => { (stmt.data as ForOfStmtData).forOfLabel = "lp"; },
			NodeKind.ForInStmt => { (stmt.data as ForInStmtData).forInLabel = "lp"; },
			NodeKind.DoWhileStmt => { (stmt.data as DoWhileStmtData).dwLabel = "lp"; },
			_ => { throw new Error("internal: label test: unexpected " + source); },
		}
		assert transAmHashNode(r.value) != before;
	}
}

test "hash sees interface extends" {
	assert parseHash("interface B {} interface A extends B {}") != parseHash("interface B {} interface A {}");
}

test "hash sees class generic params and implements" {
	assert parseHash("class C<T> { x: T; }") != parseHash("class C<U> { x: U; }");
	assert parseHash("interface I {} class C implements I {}") != parseHash("interface I {} class C {}");
}

test "hash sees call type arguments" {
	assert parseHash("const a = f<int32>();") != parseHash("const a = f<int64>();");
}

test "lowered hash ignores comments but sees line shifts" {
	const base = loweredHash("const x = 1;\nconst y = 2;");
	assert base == loweredHash("const x = 1;\nconst y = 2; // tail");
	assert base != loweredHash("\nconst x = 1;\nconst y = 2;");
}

test "lowered hash sees content" {
	assert loweredHash("const x = 1;") != loweredHash("const x = 2;");
}

test "hash sees default position among parameters" {
	assert parseHash("class C { m(a: int32, b: int32 = 1): void {} }") != parseHash("class C { m(a: int32 = 1, b: int32): void {} }");
}

test "hash sees alias generic params" {
	assert parseHash("type A<T> = int32;") != parseHash("type A<T, U> = int32;");
}

test "hash sees number literal range" {
	assert parseHash("const a = 18446744073709551616;") != parseHash("const a = 18446744073709551617;");
}

test "hash sees optional field marker" {
	assert parseHash("class C { x?: int32; }") != parseHash("class C { x: int32; }");
}

test "hash sees parser flags and ignores checker flags" {
	const r = parseSource("function f(): void {}");
	if (!r.ok) throw new Error("parse failed");
	const fn = (r.value.data as ProgramData).programStmts[0];
	const before = transAmHashNode(r.value);
	fn.flags = fn.flags.incl(NodeFlag.Sem).incl(NodeFlag.LastRead).incl(NodeFlag.OptionalChainEnd);
	assert transAmHashNode(r.value) == before;
	fn.flags = fn.flags.incl(NodeFlag.ExternC);
	assert transAmHashNode(r.value) != before;
}

test "hash sees try clause flag" {
	const r = parseSource("try { f(); } catch (e) { g(); }");
	if (!r.ok) throw new Error("parse failed");
	const t = (r.value.data as ProgramData).programStmts[0];
	const before = transAmHashNode(r.value);
	(t.data as TryCatchStmtData).hasCatchClause = false;
	assert transAmHashNode(r.value) != before;
}

test "hash sees number literal bit pattern" {
	const r = parseSource("const a = 1;");
	if (!r.ok) throw new Error("parse failed");
	const decl = (r.value.data as ProgramData).programStmts[0];
	const init = (decl.data as VariableDeclData).initializer;
	const before = transAmHashNode(r.value);
	(init.data as NumberLiteralData).isBitPattern = true;
	assert transAmHashNode(r.value) != before;
}
