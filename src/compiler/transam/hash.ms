// Trans-Am Hash Utilities — djb2 string hashing, hash combinators, AST content hashing
//
// Phase 1: simple hash for query key identification and file change detection.
// Phase 2: AST content-addressed hashing (taHashNode) for Salsa output-hash early cutoff.
//
// taHashNode hashes kind + data fields recursively, skipping positions/comments/types/symbols.
// This means comment-only or whitespace-only edits produce identical parse hashes,
// so downstream queries (TypeCheck, Transform, Analyze) stay GREEN.

import { TaQueryKey, TaQueryKind } from "./revision";
import {
	Node, NodeKind, DeclKind, ExternKind,
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
	ClassDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ExternDeclData, MacroDeclData, DecoratedDeclData, ProgramData,
	DeferStmtData, ThrowStmtData, TryCatchStmtData,
	MacroInvocationData, TestDeclData, AssertStmtData,
	QuoteExprData, ComptimeBlockData,
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";


// ===== String Hash (djb2) =====

export function taHashString(s: string): number {
	let hash = 5381;
	for (let i = 0; i < s.byteLength; i = i + 1) {
		hash = (hash * 33 + s.byteAt(i)) % 2147483647;
	}
	return hash;
}

// ===== Hash Combinators =====

export function taCombineHash(a: number, b: number): number {
	return ((a * 31) + b) % 2147483647;
}

function enumToNum(kind: TaQueryKind): number {
	return match (kind) {
		TaQueryKind.FileText => 0,
		TaQueryKind.FileHash => 1,
		TaQueryKind.Parse => 2,
		TaQueryKind.TypeCheck => 3,
		TaQueryKind.Transform => 4,
		TaQueryKind.Analyze => 5,
		TaQueryKind.ModuleDeps => 6,
		_ => 0,
	};
}

export function taHashKey(key: TaQueryKey): number {
	return taCombineHash(enumToNum(key.queryKind) * 1000003, key.fileId);
}

// ===== AST Content Hash Helpers =====

function hS(h: number, s: string): number {
	if (s === null) return taCombineHash(h, 0);
	return taCombineHash(h, taHashString(s));
}

function hI(h: number, n: number): number {
	const v = (n < 0) ? (0 - n) : n;
	return taCombineHash(h, v % 2147483647);
}

function hB(h: number, b: boolean): number {
	return taCombineHash(h, b ? 1 : 0);
}

function hN(h: number, node: Node): number {
	if (node === null) return taCombineHash(h, 0);
	return taCombineHash(h, taHashNode(node));
}

function hNodes(h: number, nodes: Node[]): number {
	if (nodes === null) return taCombineHash(h, 0);
	h = hI(h, nodes.length);
	let i = 0;
	while (i < nodes.length) {
		h = hN(h, nodes[i]);
		i = i + 1;
	}
	return h;
}

function hStrings(h: number, strs: string[]): number {
	if (strs === null) return taCombineHash(h, 0);
	h = hI(h, strs.length);
	let i = 0;
	while (i < strs.length) {
		h = hS(h, strs[i]);
		i = i + 1;
	}
	return h;
}

function hNumbers(h: number, nums: number[]): number {
	if (nums === null) return taCombineHash(h, 0);
	h = hI(h, nums.length);
	let i = 0;
	while (i < nums.length) {
		h = hI(h, nums[i]);
		i = i + 1;
	}
	return h;
}

// ===== AST Content Hash (Salsa output-hash early cutoff) =====
// Hashes node kind + data fields recursively. Skips: location, comments, nodeType, resolvedSym, flags.
// Produces identical hash for structurally identical trees regardless of position.

export function taHashNode(node: Node): number {
	if (node === null) return 0;
	let h: number = (node.kind * 2654435761) % 2147483647;

	match (node.kind) {
		// === Literals ===
		NodeKind.NumberLiteral => {
			h = hI(h, (node.data as NumberLiteralData).value);
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
			h = hN(h, d.arrowBody); h = hS(h, d.arrowFlags); h = hS(h, d.arrowReturnType);
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
			h = hNodes(h, d.patternElements); h = hB(h, d.hasRestElement);
		},
		NodeKind.ObjectPattern => {
			const d = node.data as ObjectPatternData;
			h = hNodes(h, d.patternProps); h = hB(h, d.hasRestProp);
		},
		NodeKind.ObjectPatternProp => {
			const d = node.data as ObjectPatternPropData;
			h = hS(h, d.propKey); h = hN(h, d.propAlias);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			h = hN(h, d.destrPattern); h = hN(h, d.destrInit); h = hB(h, d.destrIsConst);
		},

		// === Statements ===
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			h = hS(h, d.declName); h = hS(h, d.declType); h = hN(h, d.initializer); h = hI(h, d.declKind as number);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			h = hN(h, d.condition); h = hN(h, d.consequent); h = hN(h, d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			h = hN(h, d.whileCondition); h = hN(h, d.whileBody);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			h = hN(h, d.forInit); h = hN(h, d.forCondition); h = hN(h, d.forUpdate); h = hN(h, d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			h = hS(h, d.forOfBinding); h = hB(h, d.forOfIsConst);
			h = hN(h, d.forOfIterable); h = hN(h, d.forOfBody); h = hN(h, d.forOfPattern);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			h = hS(h, d.forInBinding); h = hB(h, d.forInIsConst);
			h = hN(h, d.forInObject); h = hN(h, d.forInBody);
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
			h = hN(h, d.fnBody); h = hS(h, d.fnFlags); h = hS(h, d.fnReturnType);
			h = hNodes(h, d.fnDefaults); h = hS(h, d.nativeName);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			h = hN(h, d.doBody); h = hN(h, d.doCondition);
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
			h = hStrings(h, d.importNames); h = hStrings(h, d.importAliases); h = hS(h, d.importSource);
		},
		NodeKind.ExportDecl => {
			h = hN(h, (node.data as ExportDeclData).exportedDecl);
		},
		NodeKind.TypeAliasDecl => {
			const d = node.data as TypeAliasDeclData;
			h = hS(h, d.aliasName); h = hS(h, d.aliasType); h = hB(h, d.aliasIsDistinct);
			h = hS(h, d.discriminantName); h = hS(h, d.discriminantType);
			h = hStrings(h, d.variantKeys); h = hStrings(h, d.variantTypes);
		},
		NodeKind.EnumDecl => {
			const d = node.data as EnumDeclData;
			h = hS(h, d.enumName); h = hStrings(h, d.enumMembers); h = hNumbers(h, d.enumValues);
		},
		NodeKind.InterfaceDecl | NodeKind.StructDecl => {
			const d = node.data as InterfaceDeclData;
			h = hS(h, d.interfaceName); h = hStrings(h, d.interfaceFields); h = hStrings(h, d.interfaceFieldTypes);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			h = hS(h, d.className); h = hS(h, d.classExtends); h = hNodes(h, d.classBody);
		},
		NodeKind.PropertyDecl => {
			const d = node.data as PropertyDeclData;
			h = hS(h, d.propName); h = hS(h, d.propType); h = hB(h, d.propIsStatic);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			h = hS(h, d.methodName); h = hStrings(h, d.methodParams); h = hStrings(h, d.methodParamTypes);
			h = hN(h, d.methodBody); h = hB(h, d.methodIsStatic);
			h = hS(h, d.methodFlags); h = hS(h, d.methodReturnType); h = hS(h, d.nativeName);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			h = hStrings(h, d.ctorParams); h = hStrings(h, d.ctorParamTypes); h = hN(h, d.ctorBody);
		},
		NodeKind.ExternDecl => {
			const d = node.data as ExternDeclData;
			h = hI(h, d.externKind as number); h = hS(h, d.externName); h = hS(h, d.nativeName); h = hS(h, d.externType);
		},

		// === Error Handling ===
		NodeKind.ThrowStmt => {
			h = hN(h, (node.data as ThrowStmtData).throwArg);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			h = hN(h, d.tryBody); h = hS(h, d.catchName); h = hN(h, d.catchBody); h = hN(h, d.finallyBody);
		},

		// === Decorators ===
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			h = hS(h, d.macroName); h = hNodes(h, d.macroArgs);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			h = hNodes(h, d.decorators); h = hN(h, d.decoratedNode);
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
			h = hN(h, d.assertExpr); h = hS(h, d.assertSource); h = hS(h, d.assertMessage);
		},
		NodeKind.MacroDecl => {
			const d = node.data as MacroDeclData;
			h = hS(h, d.macroDeclName); h = hStrings(h, d.macroDeclParams); h = hN(h, d.macroDeclBody);
		},
		NodeKind.QuoteExpr => {
			h = hN(h, (node.data as QuoteExprData).quoteBody);
		},
		NodeKind.ComptimeBlock => {
			h = hN(h, (node.data as ComptimeBlockData).comptimeBody);
		},

		// === Program Root ===
		NodeKind.Program => {
			h = hNodes(h, (node.data as ProgramData).programStmts);
		},

		_ => {},
	};

	return h;
}


// ===== Tests =====
test "empty string has known value" {
	const h = taHashString("");
	assert h === 5381;
}

test "same string same hash" { assert taHashString("hello") === taHashString("hello"); }

test "different strings different hashes" { assert taHashString("abc") !== taHashString("xyz"); }

test "single char" {
	const h = taHashString("a");
	assert h !== 5381;  // different from empty
	assert h !== 0;
}

test "combine is deterministic" { assert taCombineHash(1, 2) === taCombineHash(1, 2); }

test "order matters" { assert taCombineHash(1, 2) !== taCombineHash(2, 1); }

test "different kinds produce different hashes" {
	const a: TaQueryKey = { queryKind: 0, fileId: 1 };
	const b: TaQueryKey = { queryKind: 1, fileId: 1 };
	assert taHashKey(a) !== taHashKey(b);
}

test "different fileIds produce different hashes" {
	const a: TaQueryKey = { queryKind: 0, fileId: 1 };
	const b: TaQueryKey = { queryKind: 0, fileId: 2 };
	assert taHashKey(a) !== taHashKey(b);
}

test "null node hashes to zero" {
	assert taHashNode(null as unknown as Node) === 0;
}

test "same AST same hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const x = 1;");
	assert r1.ok;
	assert r2.ok;
	assert taHashNode(r1.value) === taHashNode(r2.value);
}

test "comment-only change same hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const x = 1; // comment");
	assert r1.ok;
	assert r2.ok;
	assert taHashNode(r1.value) === taHashNode(r2.value);
}

test "different code different hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const x = 2;");
	assert r1.ok;
	assert r2.ok;
	assert taHashNode(r1.value) !== taHashNode(r2.value);
}

test "different identifier different hash" {

	const r1 = parseSource("const x = 1;");
	const r2 = parseSource("const y = 1;");
	assert r1.ok;
	assert r2.ok;
	assert taHashNode(r1.value) !== taHashNode(r2.value);
}
