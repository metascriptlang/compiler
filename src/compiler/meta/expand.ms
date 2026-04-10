// src/compiler/meta/expand.ms
//
// Phase B v1 — Macro expansion pass.
//
// Walks the program AST, finds user-defined MacroInvocation nodes, runs the
// matching macro body in the Raiser VM, deserializes the result via valueToNode,
// and splices it back into the AST.
//
// What works in v1:
//   - Macros that return plain object literals matching the Node serialization
//     shape (e.g., `return { kind: 0, line: 1, column: 1, value: 42 };`)
//   - Macros with arguments — args are bound as wrapper-Program const decls
//   - Recursive expansion: macro outputs containing macros are re-walked
//   - Built-in directives (@emit, @include, @target, etc.) pass through unchanged
//
// What doesn't work in v1 (deferred to later phases):
//   - createNodeAt(...) calls inside macro body (Raiser doesn't import std/meta)
//   - quote { } / ${} interpolation
//   - Bare name(...) invocation without @ prefix

import {
	Node, NodeKind, SourceLocation, makeLoc, createNode, createNodeAt, DeclKind,
	BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData,
	VariableDeclData, FunctionDeclData, ExportDeclData, ProgramData,
	DecoratedDeclData, MacroInvocationData,
	ObjectLiteralData, ArrayLiteralData, IdentifierData, MemberExprData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BinaryExprData, CallExprData,
	// Phase B audit fixes — additional NodeKinds for full walker coverage
	UnaryExprData, ArrayAccessData, ConditionalExprData,
	ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData,
	SwitchStmtData, SwitchCaseData, TryCatchStmtData,
	MatchStmtData, MatchExprData, MatchCaseData,
	ArrowFunctionData, FunctionExprData,
	MethodDeclData, ConstructorDeclData, ClassDeclData, PropertyDeclData,
	ThrowStmtData, DeferStmtData,
} from "../../ast/node";
import { CheckerContext, addError, createContext } from "../../checker/context";
import { callMacroEvaluator } from "./callbacks";
import { clearObjectHeap, clearArrayHeap } from "../../raiser/value";
import { RaiserContext } from "../../raiser/context";
import { valueToNode, mkNumber, mkString, mkBool, mkNull, synthToken } from "./bridge";

// ===== Built-in directives that pass through unchanged =====

function isBuiltinDirective(name: string): boolean {
	return name === "emit"
		|| name === "include"
		|| name === "compile"
		|| name === "link"
		|| name === "passC"
		|| name === "passL"
		|| name === "import"
		|| name === "comptime"
		|| name === "target"
		|| name === "runtime"
		|| name === "builtin"
		|| name === "cImport";
}

// ===== nodeToASTLiteral: Node → ObjectLiteral AST =====
//
// Converts a Node into an AST ObjectLiteral that, when evaluated by Raiser,
// produces a heap object matching nodeToValue's output for the same Node.
// This lets us bind macro arguments via wrapper-Program const declarations.
//
// MAINTENANCE: this is a third mirror of nodeToValue's field layout. When you
// add a field to nodeToValue, also add it here. The fields written here MUST
// match the fields readable by valueToNode/readNodeFromObject.
//
// Implementation strategy: build an ObjectLiteralData with kind, line, column,
// + the kind-specific fields. Recursive for child Node fields.
function nodeToASTLiteral(node: Node, loc: SourceLocation): Node {
	if (node === null) return mkNull(loc);

	const keys: string[] = [];
	const values: Node[] = [];
	const kindNum = node.kind as number;

	keys.push("kind");
	values.push(mkNumber(kindNum, loc));
	keys.push("line");
	values.push(mkNumber(node.location.line, loc));
	keys.push("column");
	values.push(mkNumber(node.location.column, loc));

	// Append kind-specific fields
	addKindFields(node, keys, values, loc);

	return createNodeAt(NodeKind.ObjectLiteral, {
		properties: values, keys, keyLocations: [],
	}, loc);
}

function addStrField(keys: string[], values: Node[], name: string, val: string, loc: SourceLocation): void {
	keys.push(name);
	values.push(mkString(val, loc));
}

function addNumField(keys: string[], values: Node[], name: string, val: number, loc: SourceLocation): void {
	keys.push(name);
	values.push(mkNumber(val, loc));
}

function addBoolField(keys: string[], values: Node[], name: string, val: boolean, loc: SourceLocation): void {
	keys.push(name);
	values.push(mkBool(val, loc));
}

function addNodeField(keys: string[], values: Node[], name: string, val: Node, loc: SourceLocation): void {
	keys.push(name);
	values.push(nodeToASTLiteral(val, loc));
}

function addNodeArrayField(keys: string[], values: Node[], name: string, arr: Node[], loc: SourceLocation): void {
	const elements: Node[] = [];
	for (const child of arr) {
		elements.push(nodeToASTLiteral(child, loc));
	}
	keys.push(name);
	values.push(createNodeAt(NodeKind.ArrayLiteral, { elements }, loc));
}

function addStrArrayField(keys: string[], values: Node[], name: string, arr: string[], loc: SourceLocation): void {
	const elements: Node[] = [];
	for (const s of arr) {
		elements.push(mkString(s, loc));
	}
	keys.push(name);
	values.push(createNodeAt(NodeKind.ArrayLiteral, { elements }, loc));
}

// Dispatcher for kind-specific fields. Mirrors nodeToValue.
// For v1, we cover the most commonly-used NodeKinds. Others get only
// kind/line/column written — if a macro reads a field we don't handle here,
// it'll see undefined and the wrapper Program will fail at runtime.
function addKindFields(node: Node, keys: string[], values: Node[], loc: SourceLocation): void {
	const k = node.kind;
	if (k === NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		addNumField(keys, values, "value", d.value, loc);
		return;
	}
	if (k === NodeKind.StringLiteral) {
		const d = node.data as StringLiteralData;
		addStrField(keys, values, "value", d.value, loc);
		return;
	}
	if (k === NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		addBoolField(keys, values, "boolValue", d.boolValue, loc);
		return;
	}
	if (k === NodeKind.NullLiteral) {
		return;
	}
	if (k === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		addStrField(keys, values, "name", d.name, loc);
		return;
	}
	if (k === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		addStrField(keys, values, "operator", d.operator, loc);
		addNodeField(keys, values, "left", d.left, loc);
		addNodeField(keys, values, "right", d.right, loc);
		return;
	}
	if (k === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		addNodeField(keys, values, "callee", d.callee, loc);
		addNodeArrayField(keys, values, "arguments", d.arguments, loc);
		return;
	}
	if (k === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		addNodeField(keys, values, "object", d.object, loc);
		addStrField(keys, values, "property", d.property, loc);
		addBoolField(keys, values, "isOptional", d.isOptional, loc);
		return;
	}
	if (k === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		addNodeArrayField(keys, values, "properties", d.properties, loc);
		addStrArrayField(keys, values, "keys", d.keys, loc);
		return;
	}
	if (k === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		addNodeArrayField(keys, values, "elements", d.elements, loc);
		return;
	}
	if (k === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		addNodeArrayField(keys, values, "statements", d.statements, loc);
		return;
	}
	if (k === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		addNodeField(keys, values, "expr", d.expr, loc);
		return;
	}
	if (k === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		addNodeField(keys, values, "argument", d.argument, loc);
		return;
	}
	if (k === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		addStrField(keys, values, "declName", d.declName, loc);
		addStrField(keys, values, "declType", d.declType, loc);
		addNodeField(keys, values, "initializer", d.initializer, loc);
		addNumField(keys, values, "declKind", d.declKind as number, loc);
		return;
	}
	// Other NodeKinds: kind/line/column only. Sufficient for v1 — most macros
	// take simple expressions (literals, identifiers, binary exprs).
}

// ===== hasUserMacroInvocation: quick predicate =====

function hasAnyMacro(nodes: Node[], ctx: CheckerContext): boolean {
	for (const n of nodes) {
		if (hasUserMacroInvocation(n, ctx)) return true;
	}
	return false;
}

function hasUserMacroInvocation(node: Node, ctx: CheckerContext): boolean {
	if (node === null) return false;
	const k = node.kind;

	if (k === NodeKind.MacroInvocation) {
		const d = node.data as MacroInvocationData;
		if (isBuiltinDirective(d.macroName)) return false;
		return ctx.macroBodyRegistry.has(d.macroName);
	}

	// Statements
	if (k === NodeKind.VariableDecl) {
		return hasUserMacroInvocation((node.data as VariableDeclData).initializer, ctx);
	}
	if (k === NodeKind.ExprStmt) {
		return hasUserMacroInvocation((node.data as ExprStmtData).expr, ctx);
	}
	if (k === NodeKind.ReturnStmt) {
		return hasUserMacroInvocation((node.data as ReturnStmtData).argument, ctx);
	}
	if (k === NodeKind.ThrowStmt) {
		return hasUserMacroInvocation((node.data as ThrowStmtData).throwArg, ctx);
	}
	if (k === NodeKind.DeferStmt) {
		return hasUserMacroInvocation((node.data as DeferStmtData).deferExpr, ctx);
	}
	if (k === NodeKind.BlockStmt) {
		return hasAnyMacro((node.data as BlockStmtData).statements, ctx);
	}
	if (k === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		return hasUserMacroInvocation(d.condition, ctx)
			|| hasUserMacroInvocation(d.consequent, ctx)
			|| hasUserMacroInvocation(d.alternate, ctx);
	}
	if (k === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		return hasUserMacroInvocation(d.whileCondition, ctx)
			|| hasUserMacroInvocation(d.whileBody, ctx);
	}
	if (k === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		return hasUserMacroInvocation(d.doBody, ctx)
			|| hasUserMacroInvocation(d.doCondition, ctx);
	}
	if (k === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		return hasUserMacroInvocation(d.forInit, ctx)
			|| hasUserMacroInvocation(d.forCondition, ctx)
			|| hasUserMacroInvocation(d.forUpdate, ctx)
			|| hasUserMacroInvocation(d.forBody, ctx);
	}
	if (k === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		return hasUserMacroInvocation(d.forOfIterable, ctx)
			|| hasUserMacroInvocation(d.forOfBody, ctx);
	}
	if (k === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		return hasUserMacroInvocation(d.forInObject, ctx)
			|| hasUserMacroInvocation(d.forInBody, ctx);
	}
	if (k === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		return hasUserMacroInvocation(d.switchDisc, ctx)
			|| hasAnyMacro(d.switchCases, ctx);
	}
	if (k === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		return hasAnyMacro(d.caseTests, ctx) || hasAnyMacro(d.caseStmts, ctx);
	}
	if (k === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		return hasUserMacroInvocation(d.matchStmtDisc, ctx)
			|| hasAnyMacro(d.matchStmtCases, ctx);
	}
	if (k === NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		return hasAnyMacro(d.casePatterns, ctx)
			|| hasUserMacroInvocation(d.caseGuard, ctx)
			|| hasUserMacroInvocation(d.caseBody, ctx);
	}
	if (k === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		return hasUserMacroInvocation(d.tryBody, ctx)
			|| hasUserMacroInvocation(d.catchBody, ctx)
			|| hasUserMacroInvocation(d.finallyBody, ctx);
	}

	// Expressions
	if (k === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		return hasUserMacroInvocation(d.left, ctx) || hasUserMacroInvocation(d.right, ctx);
	}
	if (k === NodeKind.UnaryExpr) {
		return hasUserMacroInvocation((node.data as UnaryExprData).operand, ctx);
	}
	if (k === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		return hasUserMacroInvocation(d.callee, ctx) || hasAnyMacro(d.arguments, ctx);
	}
	if (k === NodeKind.MemberExpr) {
		return hasUserMacroInvocation((node.data as MemberExprData).object, ctx);
	}
	if (k === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		return hasUserMacroInvocation(d.array, ctx) || hasUserMacroInvocation(d.index, ctx);
	}
	if (k === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		return hasUserMacroInvocation(d.ternaryCondition, ctx)
			|| hasUserMacroInvocation(d.ternaryConsequent, ctx)
			|| hasUserMacroInvocation(d.ternaryAlternate, ctx);
	}
	if (k === NodeKind.ObjectLiteral) {
		return hasAnyMacro((node.data as ObjectLiteralData).properties, ctx);
	}
	if (k === NodeKind.ArrayLiteral) {
		return hasAnyMacro((node.data as ArrayLiteralData).elements, ctx);
	}
	if (k === NodeKind.ArrowFunction) {
		return hasUserMacroInvocation((node.data as ArrowFunctionData).arrowBody, ctx);
	}
	if (k === NodeKind.FunctionExpr) {
		return hasUserMacroInvocation((node.data as FunctionExprData).funcExprBody, ctx);
	}

	// Declarations
	if (k === NodeKind.FunctionDecl) {
		return hasUserMacroInvocation((node.data as FunctionDeclData).fnBody, ctx);
	}
	if (k === NodeKind.ExportDecl) {
		return hasUserMacroInvocation((node.data as ExportDeclData).exportedDecl, ctx);
	}
	if (k === NodeKind.ClassDecl) {
		return hasAnyMacro((node.data as ClassDeclData).classBody, ctx);
	}
	if (k === NodeKind.MethodDecl) {
		return hasUserMacroInvocation((node.data as MethodDeclData).methodBody, ctx);
	}
	if (k === NodeKind.ConstructorDecl) {
		return hasUserMacroInvocation((node.data as ConstructorDeclData).ctorBody, ctx);
	}
	if (k === NodeKind.PropertyDecl) {
		return hasUserMacroInvocation((node.data as PropertyDeclData).propInitializer, ctx);
	}
	if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return hasAnyMacro(d.decorators, ctx) || hasUserMacroInvocation(d.decoratedNode, ctx);
	}
	if (k === NodeKind.Program) {
		return hasAnyMacro((node.data as ProgramData).programStmts, ctx);
	}

	return false;
}

// ===== Phase D: Macro-author sugar — preprocessMacroBody =====
//
// Macro bodies execute in the Raiser VM, which doesn't have access to
// `std/meta/node.ms` exports. Without preprocessing, macro authors would have
// to write `kind: 0` instead of `kind: NodeKind.NumberLiteral`. This pass
// rewrites recognized patterns at preparation time:
//
//   NodeKind.X      →  <integer ordinal>     (for all NodeKind variants)
//   DeclKind.X      →  <integer ordinal>
//
// The rewrite is in-place, so the macro body in the registry is mutated once
// and reused on subsequent invocations. Mutation is idempotent — re-running on
// already-rewritten code is a no-op (NumberLiteral stays NumberLiteral).
//
// Limitations (acceptable for v1, document them):
//   - `NodeKind` cannot be used as a value: `const k = NodeKind.X` won't work.
//     Only direct member access: `kind: NodeKind.X` is rewritten.
//   - createNodeAt(K, D, L) calls are NOT rewritten (would need location-field
//     unification — separate phase).

// Map NodeKind member name to its integer ordinal.
// Uses match on the member name string. The actual ordinal comes from the
// imported NodeKind enum, so we don't hardcode integers.
function nodeKindOrdinal(name: string): number {
	return match (name) {
		"NumberLiteral" => NodeKind.NumberLiteral as number,
		"StringLiteral" => NodeKind.StringLiteral as number,
		"BooleanLiteral" => NodeKind.BooleanLiteral as number,
		"NullLiteral" => NodeKind.NullLiteral as number,
		"BigIntLiteral" => NodeKind.BigIntLiteral as number,
		"RegexLiteral" => NodeKind.RegexLiteral as number,
		"Identifier" => NodeKind.Identifier as number,
		"BinaryExpr" => NodeKind.BinaryExpr as number,
		"UnaryExpr" => NodeKind.UnaryExpr as number,
		"UpdateExpr" => NodeKind.UpdateExpr as number,
		"CallExpr" => NodeKind.CallExpr as number,
		"MemberExpr" => NodeKind.MemberExpr as number,
		"ArrayAccess" => NodeKind.ArrayAccess as number,
		"ObjectLiteral" => NodeKind.ObjectLiteral as number,
		"ArrayLiteral" => NodeKind.ArrayLiteral as number,
		"ArrowFunction" => NodeKind.ArrowFunction as number,
		"FunctionExpr" => NodeKind.FunctionExpr as number,
		"TypeAssertion" => NodeKind.TypeAssertion as number,
		"ConditionalExpr" => NodeKind.ConditionalExpr as number,
		"SpreadExpr" => NodeKind.SpreadExpr as number,
		"NewExpr" => NodeKind.NewExpr as number,
		"TryExpr" => NodeKind.TryExpr as number,
		"MatchExpr" => NodeKind.MatchExpr as number,
		"MatchCase" => NodeKind.MatchCase as number,
		"AwaitExpr" => NodeKind.AwaitExpr as number,
		"YieldExpr" => NodeKind.YieldExpr as number,
		"MoveExpr" => NodeKind.MoveExpr as number,
		"OutExpr" => NodeKind.OutExpr as number,
		"TypeAnnotation" => NodeKind.TypeAnnotation as number,
		"ArrayPattern" => NodeKind.ArrayPattern as number,
		"ObjectPattern" => NodeKind.ObjectPattern as number,
		"ObjectPatternProp" => NodeKind.ObjectPatternProp as number,
		"DestructuringDecl" => NodeKind.DestructuringDecl as number,
		"VariableDecl" => NodeKind.VariableDecl as number,
		"IfStmt" => NodeKind.IfStmt as number,
		"WhileStmt" => NodeKind.WhileStmt as number,
		"ForStmt" => NodeKind.ForStmt as number,
		"ForOfStmt" => NodeKind.ForOfStmt as number,
		"ForInStmt" => NodeKind.ForInStmt as number,
		"BlockStmt" => NodeKind.BlockStmt as number,
		"ExprStmt" => NodeKind.ExprStmt as number,
		"ReturnStmt" => NodeKind.ReturnStmt as number,
		"BreakStmt" => NodeKind.BreakStmt as number,
		"ContinueStmt" => NodeKind.ContinueStmt as number,
		"FunctionDecl" => NodeKind.FunctionDecl as number,
		"DoWhileStmt" => NodeKind.DoWhileStmt as number,
		"SwitchStmt" => NodeKind.SwitchStmt as number,
		"SwitchCase" => NodeKind.SwitchCase as number,
		"UnreachableStmt" => NodeKind.UnreachableStmt as number,
		"MatchStmt" => NodeKind.MatchStmt as number,
		"ImportDecl" => NodeKind.ImportDecl as number,
		"ExportDecl" => NodeKind.ExportDecl as number,
		"TypeAliasDecl" => NodeKind.TypeAliasDecl as number,
		"EnumDecl" => NodeKind.EnumDecl as number,
		"InterfaceDecl" => NodeKind.InterfaceDecl as number,
		"StructDecl" => NodeKind.StructDecl as number,
		"ClassDecl" => NodeKind.ClassDecl as number,
		"PropertyDecl" => NodeKind.PropertyDecl as number,
		"MethodDecl" => NodeKind.MethodDecl as number,
		"ConstructorDecl" => NodeKind.ConstructorDecl as number,
		"ThrowStmt" => NodeKind.ThrowStmt as number,
		"TryCatchStmt" => NodeKind.TryCatchStmt as number,
		"MacroInvocation" => NodeKind.MacroInvocation as number,
		"DecoratedDecl" => NodeKind.DecoratedDecl as number,
		"DeferStmt" => NodeKind.DeferStmt as number,
		"TestDecl" => NodeKind.TestDecl as number,
		"AssertStmt" => NodeKind.AssertStmt as number,
		"ExternDecl" => NodeKind.ExternDecl as number,
		"MacroDecl" => NodeKind.MacroDecl as number,
		"QuoteExpr" => NodeKind.QuoteExpr as number,
		"ComptimeBlock" => NodeKind.ComptimeBlock as number,
		"Program" => NodeKind.Program as number,
		"ActorDecl" => NodeKind.ActorDecl as number,
		_ => -1,
	};
}

function declKindOrdinal(name: string): number {
	return match (name) {
		"Const" => DeclKind.Const as number,
		"Let" => DeclKind.Let as number,
		"Var" => DeclKind.Var as number,
		_ => -1,
	};
}

// Try to rewrite a single MemberExpr — returns the new node if rewritten,
// or the original node unchanged if it doesn't match a known pattern.
function tryRewriteEnumMember(node: Node): Node {
	if (node === null || node.kind !== NodeKind.MemberExpr) return node;
	const d = node.data as MemberExprData;
	if (d.object === null || d.object.kind !== NodeKind.Identifier) return node;
	const objName = (d.object.data as IdentifierData).name;
	if (objName === "NodeKind") {
		const ord = nodeKindOrdinal(d.property);
		if (ord >= 0) {
			return mkNumber(ord, node.location);
		}
	}
	if (objName === "DeclKind") {
		const ord = declKindOrdinal(d.property);
		if (ord >= 0) {
			return mkNumber(ord, node.location);
		}
	}
	return node;
}

// Rewrite a `createNodeAt(K, D, L)` call into the equivalent ObjectLiteral.
// The result has fields: kind, line, column, + (D's keys/properties spread in).
// L can be either a Node (e.g., `x`) or `x.location` — we strip `.location` if present.
// Returns the new ObjectLiteral if matched, or the original node otherwise.
//
// Limitation: D must be an ObjectLiteral at the call site. A variable like
// `createNodeAt(K, dataVar, L)` can't be statically merged — left as-is.
function tryRewriteCreateNodeAt(node: Node): Node {
	if (node === null || node.kind !== NodeKind.CallExpr) return node;
	const c = node.data as CallExprData;
	if (c.callee === null || c.callee.kind !== NodeKind.Identifier) return node;
	const calleeName = (c.callee.data as IdentifierData).name;
	if (calleeName !== "createNodeAt" && calleeName !== "createNode") return node;
	if (c.arguments.length !== 3) return node;

	const kindArg = c.arguments[0];
	const dataArg = c.arguments[1];
	const locArg = c.arguments[2];

	// D must be an ObjectLiteral for v1 — otherwise we can't statically merge
	if (dataArg.kind !== NodeKind.ObjectLiteral) return node;

	// Strip x.location → x (the serialized Node has flat line/column, no nested .location)
	let locSource = locArg;
	if (locArg.kind === NodeKind.MemberExpr) {
		const m = locArg.data as MemberExprData;
		if (m.property === "location") {
			locSource = m.object;
		}
	}

	// Build the new ObjectLiteral: { kind: K, line: locSource.line, column: locSource.column, ...D }
	const dataLit = dataArg.data as ObjectLiteralData;
	const newKeys: string[] = [];
	const newProps: Node[] = [];
	newKeys.push("kind");
	newProps.push(kindArg);
	newKeys.push("line");
	newProps.push(createNodeAt(NodeKind.MemberExpr, {
		object: locSource, property: "line", isOptional: false,
	}, node.location));
	newKeys.push("column");
	newProps.push(createNodeAt(NodeKind.MemberExpr, {
		object: locSource, property: "column", isOptional: false,
	}, node.location));
	for (const k of dataLit.keys) newKeys.push(k);
	for (const p of dataLit.properties) newProps.push(p);

	return createNodeAt(NodeKind.ObjectLiteral, {
		properties: newProps, keys: newKeys, keyLocations: [],
	}, node.location);
}

// Walk the macro body in place, rewriting recognized patterns.
// Order: recurse into children FIRST, then try rewrites at this node.
// This ensures `createNodeAt(NodeKind.X, ...)` has its NodeKind.X already
// rewritten to an integer by the time tryRewriteCreateNodeAt sees it.
function preprocessNode(node: Node): Node {
	if (node === null) return node;

	// Recurse into children first (in-place mutation)
	const k = node.kind;

	if (k === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		d.initializer = preprocessNode(d.initializer);
	} else if (k === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		d.expr = preprocessNode(d.expr);
	} else if (k === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		d.argument = preprocessNode(d.argument);
	} else if (k === NodeKind.ThrowStmt) {
		const d = node.data as ThrowStmtData;
		d.throwArg = preprocessNode(d.throwArg);
	} else if (k === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		preprocessArray(d.statements);
	} else if (k === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		d.condition = preprocessNode(d.condition);
		d.consequent = preprocessNode(d.consequent);
		d.alternate = preprocessNode(d.alternate);
	} else if (k === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		d.whileCondition = preprocessNode(d.whileCondition);
		d.whileBody = preprocessNode(d.whileBody);
	} else if (k === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		d.left = preprocessNode(d.left);
		d.right = preprocessNode(d.right);
	} else if (k === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		d.operand = preprocessNode(d.operand);
	} else if (k === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		d.callee = preprocessNode(d.callee);
		preprocessArray(d.arguments);
	} else if (k === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		d.object = preprocessNode(d.object);
	} else if (k === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		preprocessArray(d.properties);
	} else if (k === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		preprocessArray(d.elements);
	} else if (k === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		d.ternaryCondition = preprocessNode(d.ternaryCondition);
		d.ternaryConsequent = preprocessNode(d.ternaryConsequent);
		d.ternaryAlternate = preprocessNode(d.ternaryAlternate);
	} else if (k === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		d.array = preprocessNode(d.array);
		d.index = preprocessNode(d.index);
	}

	// Now try rewrites at THIS node — children are already preprocessed
	const enumRewrite = tryRewriteEnumMember(node);
	if (enumRewrite !== node) return enumRewrite;

	const callRewrite = tryRewriteCreateNodeAt(node);
	if (callRewrite !== node) return callRewrite;

	return node;
}

function preprocessArray(arr: Node[]): void {
	let i = 0;
	while (i < arr.length) {
		arr[i] = preprocessNode(arr[i]);
		i = i + 1;
	}
}

// Public preprocessing entry: rewrite the macro body's recognized patterns
// in place. Idempotent.
function preprocessMacroBody(body: Node): void {
	if (body === null) return;
	preprocessNode(body);
}

// ===== expandMacroInvocation: run a single macro =====

// Exported for eager inline expansion from checkExprPass.ms
// (called when checkCallExpr detects a Macro symbol — see "Phase B+ eager")
export function expandMacroInvocation(node: Node, ctx: CheckerContext, depth: int32): Node {
	const d = node.data as MacroInvocationData;

	// Built-in directives pass through unchanged
	if (isBuiltinDirective(d.macroName)) return node;

	// Look up the macro body
	if (!ctx.macroBodyRegistry.has(d.macroName)) {
		// Not a known user macro — leave it alone (could be parsed but undefined)
		return node;
	}
	const body = ctx.macroBodyRegistry.get(d.macroName);
	const params = ctx.macroParamsRegistry.get(d.macroName);

	// Phase D: Preprocess the body to rewrite NodeKind.X / DeclKind.X member
	// access to integer literals. Mutation is in-place and idempotent — running
	// on already-preprocessed code is a no-op, so it's safe to call repeatedly.
	preprocessMacroBody(body);

	// Validate arity
	if (d.macroArgs.length !== params.length) {
		addError(ctx, "Macro '" + d.macroName + "' expects " + params.length.toString()
			+ " args, got " + d.macroArgs.length.toString(),
			node.location.line, node.location.column);
		return node;
	}

	// Build wrapper Program:
	//   const param1 = <arg1 as ObjectLiteral>;
	//   const param2 = <arg2 as ObjectLiteral>;
	//   ...macro body statements... (last ExprStmt → ReturnStmt)
	const wrapperStmts: Node[] = [];
	let pi = 0;
	while (pi < params.length) {
		const argLiteral = nodeToASTLiteral(d.macroArgs[pi], node.location);
		wrapperStmts.push(createNode(NodeKind.VariableDecl, {
			declName: params[pi],
			declType: "",
			initializer: argLiteral,
			declKind: DeclKind.Const,
			nameLocation: node.location,
		}, synthToken(node.location)));
		pi = pi + 1;
	}

	// Append macro body statements with last ExprStmt → ReturnStmt
	const bodyData = body.data as BlockStmtData;
	let si = 0;
	while (si < bodyData.statements.length) {
		const stmt = bodyData.statements[si];
		if (si === bodyData.statements.length - 1 && stmt.kind === NodeKind.ExprStmt) {
			const ed = stmt.data as ExprStmtData;
			wrapperStmts.push(createNode(NodeKind.ReturnStmt, { argument: ed.expr }, synthToken(node.location)));
		} else {
			wrapperStmts.push(stmt);
		}
		si = si + 1;
	}

	const program = createNode(NodeKind.Program, { programStmts: wrapperStmts }, synthToken(node.location));

	// Run in Raiser VM
	let vmCtx = callMacroEvaluator(program);

	// Deserialize result
	let result = valueToNode(vmCtx.lastResult, vmCtx.objectHeap, vmCtx.arrayHeap, node.location);

	// Reclaim VM heaps
	clearObjectHeap(vmCtx.objectHeap);
	clearArrayHeap(vmCtx.arrayHeap);
	vmCtx = null as unknown as RaiserContext;

	// Re-expand if result contains more macros (depth-limited)
	if (depth < 16 && hasUserMacroInvocation(result, ctx)) {
		result = walkExpand(result, ctx, depth + 1);
	}

	return result;
}

// ===== walkExpand: recursive AST walker =====
// Uses if-else (not match) to avoid DRC workaround #24, same as comptime.ms.

// Walks an array of nodes, replacing each with its expansion in place.
function walkExpandArray(arr: Node[], ctx: CheckerContext, depth: int32): void {
	let i = 0;
	while (i < arr.length) {
		arr[i] = walkExpand(arr[i], ctx, depth);
		i = i + 1;
	}
}

// In-place mutation strategy: for non-MacroInvocation nodes, recursively expand
// children by mutating the node.data fields directly. This is safe because the
// macro expansion pass owns the AST at this point — earlier passes have already
// produced it, and later passes consume it. Avoids the field-name explosion of
// rebuilding via createNode for every NodeKind.
function walkExpand(node: Node, ctx: CheckerContext, depth: int32): Node {
	if (node === null) return node;
	const k = node.kind;

	if (k === NodeKind.MacroInvocation) {
		return expandMacroInvocation(node, ctx, depth);
	}

	// Statements
	if (k === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		d.initializer = walkExpand(d.initializer, ctx, depth);
		return node;
	}
	if (k === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		d.expr = walkExpand(d.expr, ctx, depth);
		return node;
	}
	if (k === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		d.argument = walkExpand(d.argument, ctx, depth);
		return node;
	}
	if (k === NodeKind.ThrowStmt) {
		const d = node.data as ThrowStmtData;
		d.throwArg = walkExpand(d.throwArg, ctx, depth);
		return node;
	}
	if (k === NodeKind.DeferStmt) {
		const d = node.data as DeferStmtData;
		d.deferExpr = walkExpand(d.deferExpr, ctx, depth);
		return node;
	}
	if (k === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		walkExpandArray(d.statements, ctx, depth);
		return node;
	}
	if (k === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		d.condition = walkExpand(d.condition, ctx, depth);
		d.consequent = walkExpand(d.consequent, ctx, depth);
		d.alternate = walkExpand(d.alternate, ctx, depth);
		return node;
	}
	if (k === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		d.whileCondition = walkExpand(d.whileCondition, ctx, depth);
		d.whileBody = walkExpand(d.whileBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		d.doBody = walkExpand(d.doBody, ctx, depth);
		d.doCondition = walkExpand(d.doCondition, ctx, depth);
		return node;
	}
	if (k === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		d.forInit = walkExpand(d.forInit, ctx, depth);
		d.forCondition = walkExpand(d.forCondition, ctx, depth);
		d.forUpdate = walkExpand(d.forUpdate, ctx, depth);
		d.forBody = walkExpand(d.forBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		d.forOfIterable = walkExpand(d.forOfIterable, ctx, depth);
		d.forOfBody = walkExpand(d.forOfBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		d.forInObject = walkExpand(d.forInObject, ctx, depth);
		d.forInBody = walkExpand(d.forInBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		d.switchDisc = walkExpand(d.switchDisc, ctx, depth);
		walkExpandArray(d.switchCases, ctx, depth);
		return node;
	}
	if (k === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		walkExpandArray(d.caseTests, ctx, depth);
		walkExpandArray(d.caseStmts, ctx, depth);
		return node;
	}
	if (k === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		d.matchStmtDisc = walkExpand(d.matchStmtDisc, ctx, depth);
		walkExpandArray(d.matchStmtCases, ctx, depth);
		return node;
	}
	if (k === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		d.matchDisc = walkExpand(d.matchDisc, ctx, depth);
		walkExpandArray(d.matchCases, ctx, depth);
		return node;
	}
	if (k === NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		walkExpandArray(d.casePatterns, ctx, depth);
		d.caseGuard = walkExpand(d.caseGuard, ctx, depth);
		d.caseBody = walkExpand(d.caseBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		d.tryBody = walkExpand(d.tryBody, ctx, depth);
		d.catchBody = walkExpand(d.catchBody, ctx, depth);
		d.finallyBody = walkExpand(d.finallyBody, ctx, depth);
		return node;
	}

	// Expressions
	if (k === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		d.left = walkExpand(d.left, ctx, depth);
		d.right = walkExpand(d.right, ctx, depth);
		return node;
	}
	if (k === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		d.operand = walkExpand(d.operand, ctx, depth);
		return node;
	}
	if (k === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		d.callee = walkExpand(d.callee, ctx, depth);
		walkExpandArray(d.arguments, ctx, depth);
		return node;
	}
	if (k === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		d.object = walkExpand(d.object, ctx, depth);
		return node;
	}
	if (k === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		d.array = walkExpand(d.array, ctx, depth);
		d.index = walkExpand(d.index, ctx, depth);
		return node;
	}
	if (k === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		d.ternaryCondition = walkExpand(d.ternaryCondition, ctx, depth);
		d.ternaryConsequent = walkExpand(d.ternaryConsequent, ctx, depth);
		d.ternaryAlternate = walkExpand(d.ternaryAlternate, ctx, depth);
		return node;
	}
	if (k === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		walkExpandArray(d.properties, ctx, depth);
		return node;
	}
	if (k === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		walkExpandArray(d.elements, ctx, depth);
		return node;
	}
	if (k === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		d.arrowBody = walkExpand(d.arrowBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		d.funcExprBody = walkExpand(d.funcExprBody, ctx, depth);
		return node;
	}

	// Declarations
	if (k === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		d.fnBody = walkExpand(d.fnBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		d.exportedDecl = walkExpand(d.exportedDecl, ctx, depth);
		return node;
	}
	if (k === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		walkExpandArray(d.classBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		d.methodBody = walkExpand(d.methodBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		d.ctorBody = walkExpand(d.ctorBody, ctx, depth);
		return node;
	}
	if (k === NodeKind.PropertyDecl) {
		const d = node.data as PropertyDeclData;
		d.propInitializer = walkExpand(d.propInitializer, ctx, depth);
		return node;
	}
	if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		walkExpandArray(d.decorators, ctx, depth);
		d.decoratedNode = walkExpand(d.decoratedNode, ctx, depth);
		return node;
	}
	if (k === NodeKind.Program) {
		const d = node.data as ProgramData;
		walkExpandArray(d.programStmts, ctx, depth);
		return node;
	}

	return node;
}

// ===== Public API =====

export function expandMacros(program: Node, ctx: CheckerContext): Node {
	if (!hasUserMacroInvocation(program, ctx)) return program;
	return walkExpand(program, ctx, 0);
}

// ===== Tests =====

test "expand pass is no-op when no user macros" {
	// Build a tiny Program manually to avoid the parseSource → check round trip
	const loc = makeLoc(1, 0);
	const decl = createNode(NodeKind.VariableDecl, {
		declName: "x", declType: "", initializer: mkNumber(1, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const prog = createNode(NodeKind.Program, { programStmts: [decl] }, synthToken(loc));
	const ctx = createContext();
	const result = expandMacros(prog, ctx);
	assert result === prog;
}

test "expand pass is no-op when only built-in directives present" {
	const loc = makeLoc(1, 0);
	const inc = createNode(NodeKind.MacroInvocation, {
		macroName: "include", macroArgs: [mkString("foo.h", loc)],
	}, synthToken(loc));
	const stmt = createNode(NodeKind.ExprStmt, { expr: inc }, synthToken(loc));
	const prog = createNode(NodeKind.Program, { programStmts: [stmt] }, synthToken(loc));
	const ctx = createContext();
	const result = expandMacros(prog, ctx);
	// Built-in directive isn't in registry, so hasUserMacroInvocation returns false
	assert result === prog;
}

test "isBuiltinDirective recognizes well-known names" {
	assert isBuiltinDirective("emit");
	assert isBuiltinDirective("include");
	assert isBuiltinDirective("target");
	assert isBuiltinDirective("comptime");
	assert !isBuiltinDirective("answer");
	assert !isBuiltinDirective("derive");
}

// Phase D regression tests — NodeKind/DeclKind preprocessing

test "nodeKindOrdinal returns correct ordinals" {
	assert nodeKindOrdinal("NumberLiteral") === (NodeKind.NumberLiteral as number);
	assert nodeKindOrdinal("BinaryExpr") === (NodeKind.BinaryExpr as number);
	assert nodeKindOrdinal("Identifier") === (NodeKind.Identifier as number);
	assert nodeKindOrdinal("ClassDecl") === (NodeKind.ClassDecl as number);
	assert nodeKindOrdinal("Program") === (NodeKind.Program as number);
	assert nodeKindOrdinal("UnknownThing") === -1;
}

test "declKindOrdinal returns correct ordinals" {
	assert declKindOrdinal("Const") === (DeclKind.Const as number);
	assert declKindOrdinal("Let") === (DeclKind.Let as number);
	assert declKindOrdinal("Var") === (DeclKind.Var as number);
	assert declKindOrdinal("Other") === -1;
}

test "tryRewriteEnumMember rewrites NodeKind.X to NumberLiteral" {
	const loc = makeLoc(1, 0);
	const obj = createNode(NodeKind.Identifier, { name: "NodeKind" }, synthToken(loc));
	const member = createNode(NodeKind.MemberExpr, {
		object: obj, property: "NumberLiteral", isOptional: false,
	}, synthToken(loc));
	const result = tryRewriteEnumMember(member);
	assert result.kind === NodeKind.NumberLiteral;
	assert (result.data as NumberLiteralData).value === (NodeKind.NumberLiteral as number);
}

test "tryRewriteEnumMember leaves non-enum member unchanged" {
	const loc = makeLoc(1, 0);
	const obj = createNode(NodeKind.Identifier, { name: "someVar" }, synthToken(loc));
	const member = createNode(NodeKind.MemberExpr, {
		object: obj, property: "field", isOptional: false,
	}, synthToken(loc));
	const result = tryRewriteEnumMember(member);
	assert result === member;
	assert result.kind === NodeKind.MemberExpr;
}

test "preprocessMacroBody rewrites NodeKind in nested ReturnStmt" {
	const loc = makeLoc(1, 0);
	const obj = createNode(NodeKind.Identifier, { name: "NodeKind" }, synthToken(loc));
	const member = createNode(NodeKind.MemberExpr, {
		object: obj, property: "BinaryExpr", isOptional: false,
	}, synthToken(loc));
	const ret = createNode(NodeKind.ReturnStmt, { argument: member }, synthToken(loc));
	const body = createNode(NodeKind.BlockStmt, { statements: [ret] }, synthToken(loc));
	preprocessMacroBody(body);
	const stmts = (body.data as BlockStmtData).statements;
	const retData = stmts[0].data as ReturnStmtData;
	assert retData.argument.kind === NodeKind.NumberLiteral;
	assert (retData.argument.data as NumberLiteralData).value === (NodeKind.BinaryExpr as number);
}

test "tryRewriteCreateNodeAt converts call to ObjectLiteral" {
	const loc = makeLoc(1, 0);
	// Build: createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false }, x)
	// First, the kind argument is already an integer (post NodeKind preprocessing)
	const kindArg = mkNumber(NodeKind.NumberLiteral as number, loc);
	// Data: { value: 42, isFloat: false }
	const dataLit = createNode(NodeKind.ObjectLiteral, {
		properties: [mkNumber(42, loc), mkBool(false, loc)],
		keys: ["value", "isFloat"],
		keyLocations: [],
	}, synthToken(loc));
	// Loc: x (an identifier)
	const locArg = createNode(NodeKind.Identifier, { name: "x" }, synthToken(loc));
	// The call
	const call = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "createNodeAt" }, synthToken(loc)),
		arguments: [kindArg, dataLit, locArg],
		isDirectCall: true,
		resolvedOverloadIdx: 0,
	}, synthToken(loc));
	// Rewrite
	const result = tryRewriteCreateNodeAt(call);
	assert result.kind === NodeKind.ObjectLiteral;
	const od = result.data as ObjectLiteralData;
	// Should have: kind, line, column, value, isFloat
	assert od.keys.length === 5;
	assert od.keys[0] === "kind";
	assert od.keys[1] === "line";
	assert od.keys[2] === "column";
	assert od.keys[3] === "value";
	assert od.keys[4] === "isFloat";
}

test "tryRewriteCreateNodeAt strips x.location to x" {
	const loc = makeLoc(1, 0);
	// createNodeAt(0, {}, x.location)
	const kindArg = mkNumber(0, loc);
	const dataLit = createNode(NodeKind.ObjectLiteral, {
		properties: [], keys: [], keyLocations: [],
	}, synthToken(loc));
	const xIdent = createNode(NodeKind.Identifier, { name: "x" }, synthToken(loc));
	const xDotLoc = createNode(NodeKind.MemberExpr, {
		object: xIdent, property: "location", isOptional: false,
	}, synthToken(loc));
	const call = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "createNodeAt" }, synthToken(loc)),
		arguments: [kindArg, dataLit, xDotLoc],
		isDirectCall: true,
		resolvedOverloadIdx: 0,
	}, synthToken(loc));
	const result = tryRewriteCreateNodeAt(call);
	assert result.kind === NodeKind.ObjectLiteral;
	const od = result.data as ObjectLiteralData;
	// line field should be MemberExpr accessing `x.line` (not `x.location.line`)
	const lineField = od.properties[1];
	assert lineField.kind === NodeKind.MemberExpr;
	const lineMember = lineField.data as MemberExprData;
	assert lineMember.property === "line";
	assert lineMember.object.kind === NodeKind.Identifier;
	assert (lineMember.object.data as IdentifierData).name === "x";
}

test "tryRewriteCreateNodeAt leaves call alone when D is not ObjectLiteral" {
	const loc = makeLoc(1, 0);
	// createNodeAt(0, dataVar, x) — data is a variable, can't statically merge
	const kindArg = mkNumber(0, loc);
	const dataVar = createNode(NodeKind.Identifier, { name: "dataVar" }, synthToken(loc));
	const xIdent = createNode(NodeKind.Identifier, { name: "x" }, synthToken(loc));
	const call = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "createNodeAt" }, synthToken(loc)),
		arguments: [kindArg, dataVar, xIdent],
		isDirectCall: true,
		resolvedOverloadIdx: 0,
	}, synthToken(loc));
	const result = tryRewriteCreateNodeAt(call);
	// Should be unchanged
	assert result === call;
	assert result.kind === NodeKind.CallExpr;
}

test "nodeToASTLiteral builds ObjectLiteral for NumberLiteral" {
	const loc = makeLoc(2, 5);
	const numNode = mkNumber(42, loc);
	const literal = nodeToASTLiteral(numNode, loc);
	assert literal.kind === NodeKind.ObjectLiteral;
	const d = literal.data as ObjectLiteralData;
	// Should have kind, line, column, value
	assert d.keys.length === 4;
	assert d.keys[0] === "kind";
	assert d.keys[3] === "value";
	// Value at index 3 should be a NumberLiteral with the right value
	const valueNode = d.properties[3];
	assert valueNode.kind === NodeKind.NumberLiteral;
	assert (valueNode.data as NumberLiteralData).value === 42;
}

test "nodeToASTLiteral builds ObjectLiteral for Identifier" {
	const loc = makeLoc(1, 0);
	const idNode = createNode(NodeKind.Identifier, { name: "foo" }, synthToken(loc));
	const literal = nodeToASTLiteral(idNode, loc);
	assert literal.kind === NodeKind.ObjectLiteral;
	const d = literal.data as ObjectLiteralData;
	// Should have kind, line, column, name
	assert d.keys.length === 4;
	assert d.keys[3] === "name";
}

// Audit-fix regression tests — verify hasUserMacroInvocation detects macros
// in places that v1 originally missed (if condition, while body, for body, etc).

test "hasUserMacroInvocation detects macro in IfStmt condition" {
	const loc = makeLoc(1, 0);
	const ctx = createContext();
	ctx.macroBodyRegistry.set("foo", createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc)));
	ctx.macroParamsRegistry.set("foo", []);
	const inv = createNode(NodeKind.MacroInvocation, { macroName: "foo", macroArgs: [] }, synthToken(loc));
	const ifNode = createNode(NodeKind.IfStmt, {
		condition: inv,
		consequent: createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc)),
		alternate: null as unknown as Node,
	}, synthToken(loc));
	assert hasUserMacroInvocation(ifNode, ctx);
}

test "hasUserMacroInvocation detects macro in WhileStmt condition" {
	const loc = makeLoc(1, 0);
	const ctx = createContext();
	ctx.macroBodyRegistry.set("foo", createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc)));
	ctx.macroParamsRegistry.set("foo", []);
	const inv = createNode(NodeKind.MacroInvocation, { macroName: "foo", macroArgs: [] }, synthToken(loc));
	const whileNode = createNode(NodeKind.WhileStmt, {
		whileCondition: inv,
		whileBody: createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc)),
	}, synthToken(loc));
	assert hasUserMacroInvocation(whileNode, ctx);
}

test "hasUserMacroInvocation detects macro in ForStmt body" {
	const loc = makeLoc(1, 0);
	const ctx = createContext();
	ctx.macroBodyRegistry.set("foo", createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc)));
	ctx.macroParamsRegistry.set("foo", []);
	const inv = createNode(NodeKind.MacroInvocation, { macroName: "foo", macroArgs: [] }, synthToken(loc));
	const stmt = createNode(NodeKind.ExprStmt, { expr: inv }, synthToken(loc));
	const body = createNode(NodeKind.BlockStmt, { statements: [stmt] }, synthToken(loc));
	const forNode = createNode(NodeKind.ForStmt, {
		forInit: null as unknown as Node,
		forCondition: null as unknown as Node,
		forUpdate: null as unknown as Node,
		forBody: body,
	}, synthToken(loc));
	assert hasUserMacroInvocation(forNode, ctx);
}

test "hasUserMacroInvocation detects macro in ClassDecl body" {
	const loc = makeLoc(1, 0);
	const ctx = createContext();
	ctx.macroBodyRegistry.set("foo", createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc)));
	ctx.macroParamsRegistry.set("foo", []);
	const inv = createNode(NodeKind.MacroInvocation, { macroName: "foo", macroArgs: [] }, synthToken(loc));
	const stmt = createNode(NodeKind.ExprStmt, { expr: inv }, synthToken(loc));
	const method = createNode(NodeKind.MethodDecl, {
		methodName: "m", methodParams: [], methodParamTypes: [],
		methodBody: createNode(NodeKind.BlockStmt, { statements: [stmt] }, synthToken(loc)),
		methodIsStatic: false, methodFlags: "", methodReturnType: "",
		nativeName: "", nameLocation: loc,
	}, synthToken(loc));
	const cls = createNode(NodeKind.ClassDecl, {
		className: "C", classExtends: "", classBody: [method], nameLocation: loc,
	}, synthToken(loc));
	assert hasUserMacroInvocation(cls, ctx);
}

test "hasUserMacroInvocation detects macro in DecoratedDecl decorators" {
	const loc = makeLoc(1, 0);
	const ctx = createContext();
	ctx.macroBodyRegistry.set("derive", createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc)));
	ctx.macroParamsRegistry.set("derive", []);
	const inv = createNode(NodeKind.MacroInvocation, { macroName: "derive", macroArgs: [] }, synthToken(loc));
	const inner = createNode(NodeKind.InterfaceDecl, {
		interfaceName: "X", interfaceFields: [], interfaceFieldTypes: [], nameLocation: loc,
	}, synthToken(loc));
	const dec = createNode(NodeKind.DecoratedDecl, {
		decorators: [inv], decoratedNode: inner,
	}, synthToken(loc));
	assert hasUserMacroInvocation(dec, ctx);
}

