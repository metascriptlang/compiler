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
	QuoteExprData,
	// Additional NodeKinds for full walker coverage
	UnaryExprData, ArrayAccessData, ConditionalExprData,
	ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData,
	SwitchStmtData, SwitchCaseData, TryCatchStmtData,
	MatchStmtData, MatchExprData, MatchCaseData,
	ArrowFunctionData, FunctionExprData,
	MethodDeclData, ConstructorDeclData, ClassDeclData, PropertyDeclData,
	ThrowStmtData, DeferStmtData,
	// Strip checker-inserted wrappers when serializing macro args
	HiddenDerefData, HiddenStdConvData,
	// Type AST — Step 3 SERIALIZE: emit nodeType + type-AST kind fields
	TypeObjectData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeGenericData, TypeFunctionData,
	// SERIALIZE A2 — macro multi-decl emission
	SpliceManyData,
	// JSX (compile-time only — addKindFields cases for quote {<...>})
	JSXElementData, JSXFragmentData, JSXTextData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData,
	// Full addKindFields parity with bridge.ms nodeToValue (macros read fields of any NodeKind)
	BigIntLiteralData, RegexLiteralData, UpdateExprData, TypeAssertionData, SpreadExprData,
	NewExprData, TryExprData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData,
	ComptimeBlockData, TypeAnnotationData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	DestructuringDeclData, BreakStmtData, ContinueStmtData, UnreachableStmtData, ImportDeclData,
	TypeAliasDeclData, EnumDeclData, InterfaceDeclData, ActorDeclData, ExternDeclData, MacroDeclData,
	TestDeclData, AssertStmtData,
	// SymbolKind for Case 2 enum-member rewrite (Bug B Layer 2)
	SymbolKind, NodeFlag, Symbol,
} from "../../ast/node";
import { CheckerContext, Severity, addError, addErrorFullRange, createContext } from "../../checker/context";
import { walkNode, mapChildren } from "../../transform/walker";
import { hasGenericParams } from "../../checker/types";
import { lookupModuleCtx } from "../../checker/instantiate";
import { lookupSymbol } from "../../checker/symbol";
import { TypeKind } from "../../ast/node";
import { callMacroEngineCompiler, EngineMacroResult, setMacroDeclModulePath } from "./callbacks";
import { cloneNodeForCheck } from "../../monomorphize/clone";
import { clearObjectHeap, clearArrayHeap, heapObjectGetField, RaiserValueKind, RaiserValue } from "../../raiser/value";
import { RaiserContext } from "../../raiser/context";
import { RaiserVM, vmCallFunction } from "../../raiser/vm";
import { valueToNode, nodeToValue, mkNumber, mkString, mkBool, mkNull, synthToken, mapTypeToAst, registerBoundSym } from "./bridge";
import { ensureShaped } from "../../checker/resolvePass";
import { parseIntStr } from "../../utils/string";
import { addWarning } from "../../checker/context";

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
		|| name === "platform"
		|| name === "runtime"
		|| name === "builtin"
		|| name === "cImport";
}

// ===== Quote lowering: quote { code } → ObjectLiteral AST =====
//
// Converts a QuoteExpr into an ObjectLiteral tree at preprocessing time
// (before Raiser execution). splice(expr) inside the quote body emits the
// arg expression directly — the Raiser evaluates it at runtime and inserts
// the resulting Node value. Everything else becomes literal ObjectLiteral
// data via nodeToASTLiteral.

// Flag: when true, nodeToASTLiteral checks for splice() calls and emits
// their argument expressions as-is instead of lowering to ObjectLiteral.
let _quoteSpliceActive = false;

function isSpliceCall(node: Node | null): boolean {
	if (node === null || node.kind !== NodeKind.CallExpr) return false;
	const cd = node.data as CallExprData;
	if (cd.callee === null || cd.callee.kind !== NodeKind.Identifier) return false;
	return (cd.callee.data as IdentifierData).name === "splice" && cd.arguments.length === 1;
}

function lowerQuoteExpr(node: Node): Node {
	const d = node.data as QuoteExprData;
	const body = d.quoteBody;
	if (body === null) return mkNull(node.location);
	const loc = node.location;

	// Enable splice detection in nodeToASTLiteral
	_quoteSpliceActive = true;

	let result: Node;
	const bd = body.data as BlockStmtData;
	// Single-expression shorthand: quote { expr } → lower the expr
	if (bd.statements.length === 1 && bd.statements[0].kind === NodeKind.ExprStmt) {
		const inner = (bd.statements[0].data as ExprStmtData).expr;
		// Top-level splice: quote { splice(x) } → just x
		if (isSpliceCall(inner)) {
			result = (inner.data as CallExprData).arguments[0];
		} else {
			result = nodeToASTLiteral(inner, loc);
		}
	} else {
		// Multi-statement or non-expression: lower the entire BlockStmt
		result = nodeToASTLiteral(body, loc);
	}

	_quoteSpliceActive = false;
	return result;
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
// Strip checker-inserted wrappers (HiddenDeref/HiddenAddr/HiddenStdConv/
// HiddenSubConv) so a macro sees the source-form AST, not the C-codegen
// details (auto-deref of class pointers, implicit numeric casts).
function stripMacroArgWrappers(node: Node): Node {
	let n = node;
	while (n !== null && (n.kind === NodeKind.HiddenDeref || n.kind === NodeKind.HiddenAddr)) {
		n = (n.data as HiddenDerefData).expr;
	}
	if (n !== null && (n.kind === NodeKind.HiddenStdConv || n.kind === NodeKind.HiddenSubConv)) {
		n = (n.data as HiddenStdConvData).convExpr;
	}
	return n;
}

function nodeToASTLiteral(node: Node | null, loc: SourceLocation): Node {
	if (node === null) return mkNull(loc);
	node = stripMacroArgWrappers(node);
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
	if (node.location.endLine > 0) {
		keys.push("endLine");
		values.push(mkNumber(node.location.endLine, loc));
		keys.push("endColumn");
		values.push(mkNumber(node.location.endColumn, loc));
	}

	// Append kind-specific fields
	addKindFields(node, keys, values, loc);

	// Type introspection (SERIALIZE Phase A1): if the host node has resolved
	// type info, synthesize the type AST and embed it as `nodeType` field.
	// Macros read `value.nodeType.kind`, `value.nodeType.typExprFieldNames`, etc.
	// Synthesized type-AST nodes have nodeType=null (createNode default), so
	// recursion terminates one level deep.
	//
	// Fallback to nodeTypeAst (a Node-form type-AST cached during macro VM
	// round-trip) when nodeType (the Type form) is null. This propagates
	// type info through nested macro expansion chains where readNodeFromObject
	// can reconstruct the type-AST as Node but not as Type. Fixes Bug 6.
	if (node.nodeType !== null) {
		const typeAst = mapTypeToAst(node.nodeType, loc);
		keys.push("nodeType");
		values.push(nodeToASTLiteral(typeAst, loc));
	} else if (node.nodeTypeAst !== null) {
		keys.push("nodeType");
		values.push(nodeToASTLiteral(node.nodeTypeAst, loc));
	}

	// Symbol introspection: surface name + kind for nodes the checker bound
	// to a Symbol. Forward-only — macros read `value.resolvedSym.name`.
	// declNode skipped to avoid Symbol↔Node cycle (V2 if codecs need decl site).
	if (node.resolvedSym !== null) {
		const symKeys: string[] = ["name", "kind"];
		const symValues: Node[] = [
			mkString(node.resolvedSym.name, loc),
			mkNumber(node.resolvedSym.symbolKind as number, loc),
		];
		keys.push("resolvedSym");
		values.push(createNodeAt(NodeKind.ObjectLiteral, {
			properties: symValues, keys: symKeys, keyLocations: [],
		}, loc));
	}
	if (node.resolvedSym !== null && (node.flags & NodeFlag.BoundSym) !== 0) {
		keys.push("symHandle");
		values.push(mkNumber(registerBoundSym(node.resolvedSym), loc));
	}

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

function addNodeField(keys: string[], values: Node[], name: string, val: Node | null, loc: SourceLocation): void {
	keys.push(name);
	// splice(expr) inside a quote body: emit the arg expression directly
	// (Raiser evaluates at runtime) instead of converting to ObjectLiteral.
	if (_quoteSpliceActive && isSpliceCall(val)) {
		values.push((val.data as CallExprData).arguments[0]);
	} else {
		values.push(nodeToASTLiteral(val, loc));
	}
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

// V2 — emit Node[][] as ArrayLiteral of ArrayLiteral of Node-AST-literals.
// Macro reads `arr[i][j]` to get the j-th decorator of the i-th field.
function addNodeArrayArrayField(keys: string[], values: Node[], name: string, arr: Node[][], loc: SourceLocation): void {
	const outerElements: Node[] = [];
	for (const inner of arr) {
		const innerElements: Node[] = [];
		for (const child of inner) {
			innerElements.push(nodeToASTLiteral(child, loc));
		}
		outerElements.push(createNodeAt(NodeKind.ArrayLiteral, { elements: innerElements }, loc));
	}
	keys.push(name);
	values.push(createNodeAt(NodeKind.ArrayLiteral, { elements: outerElements }, loc));
}

// Dispatcher for kind-specific fields. Source-form serialization for the
// macro arg-passing path — converts Node data into ObjectLiteral source code
// inlined into the wrapper Program. (Distinct from the heap-based serialization
// in bridge.ms `nodeToValue`; both must cover the same NodeKinds but produce
// different output shapes. Update BOTH when adding new NodeKinds, or macros
// will see undefined fields.)
//
// Full parity with bridge.ms nodeToValue: every NodeKind with data fields is
// covered (src/test/native/programs/macroNodeFields.ms locks this at runtime).
// Kinds reaching the fall-through have no fields, or are stripped earlier.
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
	if (k === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		addNodeField(keys, values, "array", d.array, loc);
		addNodeField(keys, values, "index", d.index, loc);
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
	if (k === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		addStrField(keys, values, "unaryOp", d.unaryOp, loc);
		addNodeField(keys, values, "operand", d.operand, loc);
		return;
	}
	if (k === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		addNodeField(keys, values, "ternaryCondition", d.ternaryCondition, loc);
		addNodeField(keys, values, "ternaryConsequent", d.ternaryConsequent, loc);
		addNodeField(keys, values, "ternaryAlternate", d.ternaryAlternate, loc);
		return;
	}
	if (k === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		addNodeField(keys, values, "condition", d.condition, loc);
		addNodeField(keys, values, "consequent", d.consequent, loc);
		addNodeField(keys, values, "alternate", d.alternate, loc);
		return;
	}
	if (k === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		addNodeField(keys, values, "whileCondition", d.whileCondition, loc);
		addNodeField(keys, values, "whileBody", d.whileBody, loc);
		return;
	}
	if (k === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		addStrField(keys, values, "fnName", d.fnName, loc);
		addStrArrayField(keys, values, "params", d.params, loc);
		addStrArrayField(keys, values, "fnParamTypes", d.fnParamTypes, loc);
		addNodeField(keys, values, "fnBody", d.fnBody, loc);
		addStrField(keys, values, "fnFlags", d.fnFlags, loc);
		addStrField(keys, values, "fnReturnType", d.fnReturnType, loc);
		addNodeArrayField(keys, values, "fnDefaults", d.fnDefaults, loc);
		return;
	}
	if (k === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		addStrArrayField(keys, values, "arrowParams", d.arrowParams, loc);
		addStrArrayField(keys, values, "arrowParamTypes", d.arrowParamTypes, loc);
		addNodeField(keys, values, "arrowBody", d.arrowBody, loc);
		addStrField(keys, values, "arrowFlags", d.arrowFlags, loc);
		addStrField(keys, values, "arrowReturnType", d.arrowReturnType, loc);
		return;
	}

	// Type AST kinds — synthesized by mapTypeToAst when nodeType is emitted.
	// Macros walk these to introspect types (typExprFieldNames, typExprBase, etc.).
	if (k === NodeKind.TypeObject) {
		const d = node.data as TypeObjectData;
		addStrArrayField(keys, values, "typExprFieldNames", d.typExprFieldNames, loc);
		addNodeArrayField(keys, values, "typExprFieldTypes", d.typExprFieldTypes, loc);
		if (d.typExprIndexKey !== null) addNodeField(keys, values, "typExprIndexKey", d.typExprIndexKey, loc);
		if (d.typExprIndexValue !== null) addNodeField(keys, values, "typExprIndexValue", d.typExprIndexValue, loc);
		addNodeArrayArrayField(keys, values, "typExprFieldDecorators", d.typExprFieldDecorators, loc);
		addStrField(keys, values, "typExprTypeName", d.typExprTypeName, loc);
		return;
	}
	if (k === NodeKind.TypeArray) {
		const d = node.data as TypeArrayData;
		addNodeField(keys, values, "typExprElement", d.typExprElement, loc);
		addNumField(keys, values, "typExprSize", d.typExprSize, loc);
		return;
	}
	if (k === NodeKind.TypeUnion) {
		const d = node.data as TypeUnionData;
		addNodeArrayField(keys, values, "typExprMembers", d.typExprMembers, loc);
		// V3 disc metadata — bridge populates for match-type DUs; empty for TS-style.
		addStrField(keys, values, "discFieldName", d.discFieldName, loc);
		addStrArrayField(keys, values, "variantKeys", d.variantKeys, loc);
		addStrField(keys, values, "discKind", d.discKind, loc);
		return;
	}
	if (k === NodeKind.TypeIntersection) {
		const d = node.data as TypeIntersectionData;
		addNodeArrayField(keys, values, "typExprMembers", d.typExprMembers, loc);
		return;
	}
	if (k === NodeKind.TypeGeneric) {
		const d = node.data as TypeGenericData;
		addNodeField(keys, values, "typExprBase", d.typExprBase, loc);
		addNodeArrayField(keys, values, "typExprArgs", d.typExprArgs, loc);
		return;
	}
	if (k === NodeKind.TypeFunction) {
		const d = node.data as TypeFunctionData;
		addNodeArrayField(keys, values, "typExprParams", d.typExprParams, loc);
		addNodeField(keys, values, "typExprReturn", d.typExprReturn, loc);
		addStrArrayField(keys, values, "typExprParamNames", d.typExprParamNames, loc);
		return;
	}
	// JSX (compile-time only — emitted by quote {<...>} bodies)
	if (k === NodeKind.JSXElement) {
		const d = node.data as JSXElementData;
		addStrField(keys, values, "jsxTag", d.jsxTag, loc);
		addNodeArrayField(keys, values, "jsxAttrs", d.jsxAttrs, loc);
		addNodeArrayField(keys, values, "jsxChildren", d.jsxChildren, loc);
		addBoolField(keys, values, "jsxSelfClosing", d.jsxSelfClosing, loc);
		return;
	}
	if (k === NodeKind.JSXFragment) {
		const d = node.data as JSXFragmentData;
		addNodeArrayField(keys, values, "jsxFragChildren", d.jsxFragChildren, loc);
		return;
	}
	if (k === NodeKind.JSXText) {
		const d = node.data as JSXTextData;
		addStrField(keys, values, "jsxText", d.jsxText, loc);
		return;
	}
	if (k === NodeKind.JSXExpressionContainer) {
		const d = node.data as JSXExpressionContainerData;
		addNodeField(keys, values, "jsxExpr", d.jsxExpr, loc);
		return;
	}
	if (k === NodeKind.JSXAttribute) {
		const d = node.data as JSXAttributeData;
		addStrField(keys, values, "jsxAttrName", d.jsxAttrName, loc);
		addNodeField(keys, values, "jsxAttrValue", d.jsxAttrValue, loc);
		return;
	}
	if (k === NodeKind.JSXSpreadAttribute) {
		const d = node.data as JSXSpreadAttributeData;
		addNodeField(keys, values, "jsxSpreadArg", d.jsxSpreadArg, loc);
		return;
	}

	if (k === NodeKind.BigIntLiteral) {
		const d = node.data as BigIntLiteralData;
		addStrField(keys, values, "bigintValue", d.bigintValue, loc);
		return;
	}
	if (k === NodeKind.RegexLiteral) {
		const d = node.data as RegexLiteralData;
		addStrField(keys, values, "regexPattern", d.regexPattern, loc);
		return;
	}
	if (k === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		addStrField(keys, values, "updateOp", d.updateOp, loc);
		addNodeField(keys, values, "updateArg", d.updateArg, loc);
		addBoolField(keys, values, "isPrefix", d.isPrefix, loc);
		return;
	}
	if (k === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		addNodeField(keys, values, "asExpr", d.asExpr, loc);
		addStrField(keys, values, "asType", d.asType, loc);
		return;
	}
	if (k === NodeKind.SpreadExpr) {
		const d = node.data as SpreadExprData;
		addNodeField(keys, values, "spreadArg", d.spreadArg, loc);
		return;
	}
	if (k === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		addNodeField(keys, values, "newCallee", d.newCallee, loc);
		addNodeArrayField(keys, values, "newArguments", d.newArguments, loc);
		return;
	}
	if (k === NodeKind.TryExpr) {
		const d = node.data as TryExprData;
		addNodeField(keys, values, "tryArg", d.tryArg, loc);
		addBoolField(keys, values, "hasCatch", d.hasCatch, loc);
		if (d.hasCatch) { addNodeField(keys, values, "catchVal", d.catchVal, loc); }
		return;
	}
	if (k === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		addNodeField(keys, values, "matchDisc", d.matchDisc, loc);
		addNodeArrayField(keys, values, "matchCases", d.matchCases, loc);
		return;
	}
	if (k === NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		addNodeArrayField(keys, values, "casePatterns", d.casePatterns, loc);
		addNodeField(keys, values, "caseGuard", d.caseGuard, loc);
		addNodeField(keys, values, "caseBody", d.caseBody, loc);
		return;
	}
	if (k === NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		addNodeField(keys, values, "awaitArg", d.awaitArg, loc);
		return;
	}
	if (k === NodeKind.YieldExpr) {
		const d = node.data as YieldExprData;
		addNodeField(keys, values, "yieldArg", d.yieldArg, loc);
		addBoolField(keys, values, "isDelegate", d.isDelegate, loc);
		return;
	}
	if (k === NodeKind.MoveExpr) {
		const d = node.data as MoveExprData;
		addNodeField(keys, values, "moveArg", d.moveArg, loc);
		return;
	}
	if (k === NodeKind.OutExpr) {
		const d = node.data as OutExprData;
		addNodeField(keys, values, "outArg", d.outArg, loc);
		return;
	}
	if (k === NodeKind.SizeofExpr) {
		const d = node.data as SizeofExprData;
		addStrField(keys, values, "sizeofType", d.sizeofType, loc);
		return;
	}
	if (k === NodeKind.QuoteExpr) {
		const d = node.data as QuoteExprData;
		addNodeField(keys, values, "quoteBody", d.quoteBody, loc);
		return;
	}
	if (k === NodeKind.ComptimeBlock) {
		const d = node.data as ComptimeBlockData;
		addNodeField(keys, values, "comptimeBody", d.comptimeBody, loc);
		return;
	}
	if (k === NodeKind.TypeAnnotation) {
		const d = node.data as TypeAnnotationData;
		addStrField(keys, values, "annotationType", d.annotationType, loc);
		return;
	}
	if (k === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		addStrArrayField(keys, values, "funcExprParams", d.funcExprParams, loc);
		addStrArrayField(keys, values, "funcExprParamTypes", d.funcExprParamTypes, loc);
		addNodeField(keys, values, "funcExprBody", d.funcExprBody, loc);
		addStrField(keys, values, "funcExprFlags", d.funcExprFlags, loc);
		addStrField(keys, values, "funcExprReturnType", d.funcExprReturnType, loc);
		return;
	}
	if (k === NodeKind.ArrayPattern) {
		const d = node.data as ArrayPatternData;
		addNodeArrayField(keys, values, "patternElements", d.patternElements, loc);
		addBoolField(keys, values, "hasRestElement", d.hasRestElement, loc);
		return;
	}
	if (k === NodeKind.ObjectPattern) {
		const d = node.data as ObjectPatternData;
		addNodeArrayField(keys, values, "patternProps", d.patternProps, loc);
		addBoolField(keys, values, "hasRestProp", d.hasRestProp, loc);
		return;
	}
	if (k === NodeKind.ObjectPatternProp) {
		const d = node.data as ObjectPatternPropData;
		addStrField(keys, values, "propKey", d.propKey, loc);
		addNodeField(keys, values, "propAlias", d.propAlias, loc);
		return;
	}
	if (k === NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		addNodeField(keys, values, "destrPattern", d.destrPattern, loc);
		addNodeField(keys, values, "destrInit", d.destrInit, loc);
		addBoolField(keys, values, "destrIsConst", d.destrIsConst, loc);
		return;
	}
	if (k === NodeKind.ThrowStmt) {
		const d = node.data as ThrowStmtData;
		addNodeField(keys, values, "throwArg", d.throwArg, loc);
		return;
	}
	if (k === NodeKind.DeferStmt) {
		const d = node.data as DeferStmtData;
		addNodeField(keys, values, "deferExpr", d.deferExpr, loc);
		return;
	}
	if (k === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		addNodeField(keys, values, "doBody", d.doBody, loc);
		addNodeField(keys, values, "doCondition", d.doCondition, loc);
		return;
	}
	if (k === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		addNodeField(keys, values, "forInit", d.forInit, loc);
		addNodeField(keys, values, "forCondition", d.forCondition, loc);
		addNodeField(keys, values, "forUpdate", d.forUpdate, loc);
		addNodeField(keys, values, "forBody", d.forBody, loc);
		return;
	}
	if (k === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		addStrField(keys, values, "forOfBinding", d.forOfBinding, loc);
		addBoolField(keys, values, "forOfIsConst", d.forOfIsConst, loc);
		addNodeField(keys, values, "forOfIterable", d.forOfIterable, loc);
		addNodeField(keys, values, "forOfBody", d.forOfBody, loc);
		return;
	}
	if (k === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		addStrField(keys, values, "forInBinding", d.forInBinding, loc);
		addBoolField(keys, values, "forInIsConst", d.forInIsConst, loc);
		addNodeField(keys, values, "forInObject", d.forInObject, loc);
		addNodeField(keys, values, "forInBody", d.forInBody, loc);
		return;
	}
	if (k === NodeKind.BreakStmt) {
		const d = node.data as BreakStmtData;
		addStrField(keys, values, "breakLabel", d.breakLabel, loc);
		return;
	}
	if (k === NodeKind.ContinueStmt) {
		const d = node.data as ContinueStmtData;
		addStrField(keys, values, "continueLabel", d.continueLabel, loc);
		return;
	}
	if (k === NodeKind.UnreachableStmt) {
		const d = node.data as UnreachableStmtData;
		addStrField(keys, values, "unreachableMsg", d.unreachableMsg, loc);
		return;
	}
	if (k === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		addNodeField(keys, values, "switchDisc", d.switchDisc, loc);
		addNodeArrayField(keys, values, "switchCases", d.switchCases, loc);
		return;
	}
	if (k === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		addNodeArrayField(keys, values, "caseTests", d.caseTests, loc);
		addNodeArrayField(keys, values, "caseStmts", d.caseStmts, loc);
		addBoolField(keys, values, "isDefault", d.isDefault, loc);
		return;
	}
	if (k === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		addNodeField(keys, values, "matchStmtDisc", d.matchStmtDisc, loc);
		addNodeArrayField(keys, values, "matchStmtCases", d.matchStmtCases, loc);
		return;
	}
	if (k === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		addNodeField(keys, values, "tryBody", d.tryBody, loc);
		addStrField(keys, values, "catchName", d.catchName, loc);
		addNodeField(keys, values, "catchBody", d.catchBody, loc);
		addNodeField(keys, values, "finallyBody", d.finallyBody, loc);
		return;
	}
	if (k === NodeKind.ImportDecl) {
		const d = node.data as ImportDeclData;
		addStrArrayField(keys, values, "importNames", d.importNames, loc);
		addStrArrayField(keys, values, "importAliases", d.importAliases, loc);
		addStrField(keys, values, "importSource", d.importSource, loc);
		return;
	}
	if (k === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		addNodeField(keys, values, "exportedDecl", d.exportedDecl, loc);
		return;
	}
	if (k === NodeKind.TypeAliasDecl) {
		const d = node.data as TypeAliasDeclData;
		addStrField(keys, values, "aliasName", d.aliasName, loc);
		addStrField(keys, values, "aliasType", d.aliasType, loc);
		addBoolField(keys, values, "aliasIsDistinct", d.aliasIsDistinct, loc);
		return;
	}
	if (k === NodeKind.EnumDecl) {
		const d = node.data as EnumDeclData;
		addStrField(keys, values, "enumName", d.enumName, loc);
		addStrArrayField(keys, values, "enumMembers", d.enumMembers, loc);
		return;
	}
	if (k === NodeKind.InterfaceDecl || k === NodeKind.StructDecl) {
		const d = node.data as InterfaceDeclData;
		addStrField(keys, values, "interfaceName", d.interfaceName, loc);
		addStrArrayField(keys, values, "interfaceFields", d.interfaceFields, loc);
		addStrArrayField(keys, values, "interfaceFieldTypes", d.interfaceFieldTypes, loc);
		return;
	}
	if (k === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		addStrField(keys, values, "className", d.className, loc);
		addStrField(keys, values, "classExtends", d.classExtends, loc);
		addNodeArrayField(keys, values, "classBody", d.classBody, loc);
		return;
	}
	if (k === NodeKind.ActorDecl) {
		const d = node.data as ActorDeclData;
		addStrField(keys, values, "actorName", d.actorName, loc);
		addNodeArrayField(keys, values, "actorBody", d.actorBody, loc);
		return;
	}
	if (k === NodeKind.PropertyDecl) {
		const d = node.data as PropertyDeclData;
		addStrField(keys, values, "propName", d.propName, loc);
		addStrField(keys, values, "propType", d.propType, loc);
		addBoolField(keys, values, "propIsStatic", d.propIsStatic, loc);
		return;
	}
	if (k === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		addStrField(keys, values, "methodName", d.methodName, loc);
		addStrArrayField(keys, values, "methodParams", d.methodParams, loc);
		addStrArrayField(keys, values, "methodParamTypes", d.methodParamTypes, loc);
		addNodeField(keys, values, "methodBody", d.methodBody, loc);
		addBoolField(keys, values, "methodIsStatic", d.methodIsStatic, loc);
		addStrField(keys, values, "methodFlags", d.methodFlags, loc);
		addStrField(keys, values, "methodReturnType", d.methodReturnType, loc);
		return;
	}
	if (k === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		addStrArrayField(keys, values, "ctorParams", d.ctorParams, loc);
		addStrArrayField(keys, values, "ctorParamTypes", d.ctorParamTypes, loc);
		addNodeField(keys, values, "ctorBody", d.ctorBody, loc);
		return;
	}
	if (k === NodeKind.ExternDecl) {
		const d = node.data as ExternDeclData;
		addNumField(keys, values, "externKind", d.externKind as number, loc);
		addStrField(keys, values, "externName", d.externName, loc);
		addStrField(keys, values, "nativeName", d.nativeName, loc);
		addStrField(keys, values, "externType", d.externType, loc);
		return;
	}
	if (k === NodeKind.MacroDecl) {
		const d = node.data as MacroDeclData;
		addStrField(keys, values, "macroDeclName", d.macroDeclName, loc);
		addStrArrayField(keys, values, "macroDeclParams", d.macroDeclParams, loc);
		addStrArrayField(keys, values, "macroDeclParamTypes", d.macroDeclParamTypes, loc);
		addNodeField(keys, values, "macroDeclBody", d.macroDeclBody, loc);
		return;
	}
	if (k === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		addNodeArrayField(keys, values, "decorators", d.decorators, loc);
		addNodeField(keys, values, "decoratedNode", d.decoratedNode, loc);
		return;
	}
	if (k === NodeKind.MacroInvocation) {
		const d = node.data as MacroInvocationData;
		addStrField(keys, values, "macroName", d.macroName, loc);
		addNodeArrayField(keys, values, "macroArgs", d.macroArgs, loc);
		return;
	}
	if (k === NodeKind.TestDecl) {
		const d = node.data as TestDeclData;
		addStrField(keys, values, "testName", d.testName, loc);
		addNodeField(keys, values, "testBody", d.testBody, loc);
		return;
	}
	if (k === NodeKind.AssertStmt) {
		const d = node.data as AssertStmtData;
		addNodeField(keys, values, "assertExpr", d.assertExpr, loc);
		addStrField(keys, values, "assertSource", d.assertSource, loc);
		addStrField(keys, values, "assertMessage", d.assertMessage, loc);
		addNodeField(keys, values, "assertMessageExpr", d.assertMessageExpr, loc);
		return;
	}
	if (k === NodeKind.Program) {
		const d = node.data as ProgramData;
		addNodeArrayField(keys, values, "programStmts", d.programStmts, loc);
		return;
	}
	if (k === NodeKind.SpliceMany) {
		const d = node.data as SpliceManyData;
		addNodeArrayField(keys, values, "spliceNodes", d.spliceNodes, loc);
		return;
	}

	// Every NodeKind is handled above or stripped before reaching here (Hidden*
	// wrappers, see nodeToASTLiteral L141-153) — full parity with bridge.ms nodeToValue.
	// A NodeKind reaching this point means addKindFields wasn't updated for a newly
	// added kind: fail loud. A silent fall-through would serialize kind/line/column
	// only, so a macro reading the missing field aborts cryptically downstream
	// ("array handle out of bounds") instead of pointing here.
	unreachable;
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
		// Type-AST kinds (synthesized by mapTypeToAst, read by codec macros)
		"TypeGeneric" => NodeKind.TypeGeneric as number,
		"TypeArray" => NodeKind.TypeArray as number,
		"TypeUnion" => NodeKind.TypeUnion as number,
		"TypeIntersection" => NodeKind.TypeIntersection as number,
		"TypeFunction" => NodeKind.TypeFunction as number,
		"TypeObject" => NodeKind.TypeObject as number,
		// SERIALIZE A2 — multi-decl emission
		"SpliceMany" => NodeKind.SpliceMany as number,
		// JSX (compile-time only — for NodeKind.JSXElement rewriting in macro bodies)
		"JSXElement" => NodeKind.JSXElement as number,
		"JSXFragment" => NodeKind.JSXFragment as number,
		"JSXText" => NodeKind.JSXText as number,
		"JSXExpressionContainer" => NodeKind.JSXExpressionContainer as number,
		"JSXAttribute" => NodeKind.JSXAttribute as number,
		"JSXSpreadAttribute" => NodeKind.JSXSpreadAttribute as number,
		// Self-hosting / hidden conversions (rare but technically constructable)
		"SizeofExpr" => NodeKind.SizeofExpr as number,
		"HiddenDeref" => NodeKind.HiddenDeref as number,
		"HiddenAddr" => NodeKind.HiddenAddr as number,
		"HiddenStdConv" => NodeKind.HiddenStdConv as number,
		"HiddenSubConv" => NodeKind.HiddenSubConv as number,
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

// Lookup a member ordinal for our known macro-facing enums. Returns -1 for
// unknown enum names so callers can no-op.
function macroEnumOrdinal(enumName: string, memberName: string): number {
	return match (enumName) {
		"NodeKind" => nodeKindOrdinal(memberName),
		"DeclKind" => declKindOrdinal(memberName),
		_ => -1,
	};
}

// Try to rewrite a known enum-member access to its integer ordinal.
// Returns the new node if rewritten, or the original node unchanged.
//
// Two surface forms must be handled — they look identical in source but the
// checker resolves them differently depending on when preprocessing runs:
//
//   1. Raw MemberExpr(Identifier("NodeKind"), "TypeObject") — pre-check form.
//      Matches macro bodies that get preprocessed BEFORE the checker walks
//      them (preprocessMacroBody on the macro body in expandMacroInvocation).
//
//   2. Resolved Identifier with resolvedSym.symbolKind=EnumMember — post-check
//      form. Matches injected helper bodies whose source module was already
//      checked when its file was first compiled (checkExprPass.ms:3573 mutates
//      the node in place: kind→Identifier, data→{name:mangledName},
//      resolvedSym→memberSym). Without this case, helpers like
//      detectUnionDisc calling peelVariant see `NodeKind.TypeObject` as a
//      mangled Identifier the Raiser VM can't look up (evaluates to nil), and
//      `v0.kind === NodeKind.TypeObject` always returns false (Bug B Layer 2).
function tryRewriteEnumMember(node: Node): Node {
	if (node === null) return node;
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		if (d.object === null || d.object.kind !== NodeKind.Identifier) return node;
		const ord = macroEnumOrdinal((d.object.data as IdentifierData).name, d.property);
		return ord >= 0 ? mkNumber(ord, node.location) : node;
	}
	if (node.kind === NodeKind.Identifier && node.resolvedSym !== null) {
		const sym = node.resolvedSym;
		if (sym.symbolKind === SymbolKind.EnumMember && sym.symbolType !== null) {
			const ord = macroEnumOrdinal(sym.symbolType.typeName, sym.name);
			if (ord >= 0) return mkNumber(ord, node.location);
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

// Compile-time diagnostics: `error("msg")` halts expansion and surfaces as
// checker error; `warning("msg")` surfaces as checker warning but continues.
// Rewritten to return statements with sentinel objects that expandMacroInvocation
// detects before calling valueToNode.
// Builds a MemberExpr: `obj.prop`
function mkMember(obj: Node, prop: string, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.MemberExpr, { object: obj, property: prop, isOptional: false }, loc);
}

function tryRewriteCompileError(node: Node): Node {
	if (node === null || node.kind !== NodeKind.ExprStmt) return node;
	const ed = node.data as ExprStmtData;
	if (ed.expr === null || ed.expr.kind !== NodeKind.CallExpr) return node;
	const cd = ed.expr.data as CallExprData;
	if (cd.callee === null || cd.callee.kind !== NodeKind.Identifier) return node;
	const name = (cd.callee.data as IdentifierData).name;
	if (name !== "error" && name !== "warning") return node;
	if (cd.arguments.length < 1 || cd.arguments.length > 2) return node;
	const loc = node.location;
	const msgArg = cd.arguments[0];
	// 2-arg form: error("msg", astNode) — location from the input AST node.
	// astNode.line and astNode.column carry the original source position.
	const hasLoc = cd.arguments.length === 2;
	const locNode = hasLoc ? cd.arguments[1] : null as unknown as Node;
	if (name === "error") {
		// error("msg") → return { __compileError: 1, message: "msg" }
		// error("msg", node) → return { ..., line, column, endLine, endColumn }
		const keys: string[] = ["__compileError", "message"];
		const props: Node[] = [mkNumber(1, loc), msgArg];
		if (hasLoc) {
			keys.push("line");
			props.push(mkMember(locNode, "line", loc));
			keys.push("column");
			props.push(mkMember(locNode, "column", loc));
			keys.push("endLine");
			props.push(mkMember(locNode, "endLine", loc));
			keys.push("endColumn");
			props.push(mkMember(locNode, "endColumn", loc));
		}
		const sentinel = createNodeAt(NodeKind.ObjectLiteral, {
			properties: props, keys, keyLocations: [],
		}, loc);
		return createNodeAt(NodeKind.ReturnStmt, { argument: sentinel }, loc);
	}
	// warning("msg") / warning("msg", node) → console.log with encoded location.
	// Non-halting — macro continues after the warning.
	// Format: "__MACRO_WARN__:msg" or "__MACRO_WARN__:msg\tline\tcol"
	let warnPayload: Node = createNodeAt(NodeKind.BinaryExpr, {
		operator: "+", left: mkString("__MACRO_WARN__:", loc), right: msgArg,
	}, loc);
	if (hasLoc) {
		// Append "\t" + line + "\t" + column for location extraction
		warnPayload = createNodeAt(NodeKind.BinaryExpr, {
			operator: "+", left: warnPayload, right: mkString("\t", loc),
		}, loc);
		warnPayload = createNodeAt(NodeKind.BinaryExpr, {
			operator: "+", left: warnPayload, right: mkMember(locNode, "line", loc),
		}, loc);
		warnPayload = createNodeAt(NodeKind.BinaryExpr, {
			operator: "+", left: warnPayload, right: mkString("\t", loc),
		}, loc);
		warnPayload = createNodeAt(NodeKind.BinaryExpr, {
			operator: "+", left: warnPayload, right: mkMember(locNode, "column", loc),
		}, loc);
	}
	const logCallee = mkMember(
		createNodeAt(NodeKind.Identifier, { name: "console" }, loc), "log", loc);
	const logCall = createNodeAt(NodeKind.CallExpr, {
		callee: logCallee, arguments: [warnPayload],
		isDirectCall: true, resolvedOverloadIdx: -1,
	}, loc);
	return createNodeAt(NodeKind.ExprStmt, { expr: logCall }, loc);
}

// Apply preprocess rewrites to a single node (post-order — assumes children
// already preprocessed). Pulls out the per-node post-rewrites previously inline
// in `preprocessNode`'s tail so the recursion can be delegated to walkNode.
function applyPreprocessRewrites(node: Node): Node {
	if (node === null) return node;

	// Phase C: quote { } lowering — convert to ObjectLiteral tree
	if (node.kind === NodeKind.QuoteExpr) {
		return lowerQuoteExpr(node);
	}

	// Compile-time error/warning: rewrite `error("msg")` and `warning("msg")`
	// in ExprStmt position to return statements with sentinel values.
	// error → halts macro (returns sentinel), warning → stores msg + continues.
	const errorRewrite = tryRewriteCompileError(node);
	if (errorRewrite !== node) return errorRewrite;

	const enumRewrite = tryRewriteEnumMember(node);
	if (enumRewrite !== node) return enumRewrite;

	const callRewrite = tryRewriteCreateNodeAt(node);
	if (callRewrite !== node) return callRewrite;

	return node;
}

// Walk the macro body in place, rewriting recognized patterns.
// Order: recurse into children FIRST (via walkNode's post-order), then
// applyPreprocessRewrites at each node. This ensures
// `createNodeAt(NodeKind.X, ...)` has its NodeKind.X already rewritten to
// an integer by the time tryRewriteCreateNodeAt sees it.
//
// Reuses src/transform/walker.ms walkNode/mapChildren — single source of
// truth for AST traversal across all NodeKinds (including ForOfStmt/MatchCase
// /TryCatchStmt etc.). Avoids the historical drift where preprocessNode
// silently skipped kinds and caused NodeKind.X access inside for..of bodies
// to evaluate as a runtime MemberExpr (returning nil).
function preprocessNode(node: Node): Node {
	return walkNode(node, applyPreprocessRewrites);
}

// Public preprocessing entry: rewrite the macro body's recognized patterns
// in place. Idempotent.
function preprocessMacroBody(body: Node): void {
	if (body === null) return;
	preprocessNode(body);
}

// ===== rewriteCallExprToMacroInvocation: post-expansion macro-call detection =====
//
// SERIALIZE Bug 6: when a deferred macro (held by A3 defer) expands post-mono,
// `valueToNode` reconstructs the AST as fresh nodes. Inner macro references
// in the result come back as `CallExpr(Identifier(macroName))` rather than
// `MacroInvocation`. The CallExpr→MacroInvocation rewrite normally lives in
// `checkExprPass.ms:1652` (checkCallExpr) which runs ONLY during eager
// expansion. Post-mono `expandMacros` skips the checker, so without this
// helper the inner macro reaches codegen as an undeclared function call.
//
// This walks the freshly-deserialized result and mutates any
// `CallExpr(Identifier(name))` whose name is in `macroBodyRegistry` to
// `MacroInvocation`. The existing re-walk loop (depth < 16 + walkExpand)
// then handles the nested expansion.
function rewriteCallExprToMacroInvocation(node: Node, ctx: CheckerContext): Node {
	if (node === null) return node;
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		if (cd.callee.kind === NodeKind.Identifier) {
			const calleeName = (cd.callee.data as IdentifierData).name;
			const calleeBound = (cd.callee.flags & NodeFlag.BoundSym) !== 0
				&& cd.callee.resolvedSym !== null
				&& cd.callee.resolvedSym.symbolKind === SymbolKind.Macro;
			if (ctx.macroBodyRegistry.has(calleeName) || calleeBound) {
				// Recurse into args first — nested macro calls inside args
				// also need the rewrite.
				let i = 0;
				while (i < cd.arguments.length) {
					cd.arguments[i] = rewriteCallExprToMacroInvocation(cd.arguments[i], ctx);
					i = i + 1;
				}
				// Mutate in place: CallExpr → MacroInvocation. Read the bound sym
				// BEFORE replacing node.data — the old CallExprData (and its
				// callee) is destroyed by the assignment.
				const boundSym = calleeBound ? cd.callee.resolvedSym : null as unknown as Symbol;
				node.kind = NodeKind.MacroInvocation;
				node.data = { macroName: calleeName, macroArgs: cd.arguments };
				if (boundSym !== null) {
					node.resolvedSym = boundSym;
					node.flags = node.flags | NodeFlag.BoundSym;
				}
				return node;
			}
		}
	}
	mapChildren(node, (child: Node): Node => rewriteCallExprToMacroInvocation(child, ctx));
	return node;
}

// ===== getTypeImpl(TypeName): bake a named type's type-AST into the body =====
//
// Macro bodies can read the type of a VALUE they receive (`arg.nodeType`), but a
// macro that validates against a FIXED interface has no value to read it from —
// a bare object-literal argument carries no contextual type at expand time. This
// resolves `getTypeImpl(Style)` in the macro's DECLARING module scope (where the
// name is in scope, not the call site's) and splices the type-AST literal in.
//
// Safe to bake into the shared body: the compiled-macro cache is keyed by macro
// name, and a named type does not vary per call site. Mutation is idempotent —
// a second pass finds literals, not calls.
function bakeTypeIntrinsics(node: Node, ctx: CheckerContext, regCtx: CheckerContext, macroName: string, typeArg: string): Node {
	if (node === null) return node;
	if (node.kind === NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		// bindSym("name") — Nim semBindSym model: resolve the name in the macro's
		// DECLARING module scope at bake time, register the real Symbol, and
		// splice an Identifier literal carrying its handle. valueToNode rebinds
		// the Symbol on the way out; the checker sees NodeFlag.BoundSym and skips
		// the user-scope lookup — no imports needed, no user-local name capture.
		if (cd.callee.kind === NodeKind.Identifier
				&& (cd.callee.data as IdentifierData).name === "bindSym") {
			if (cd.arguments.length !== 1 || cd.arguments[0].kind !== NodeKind.StringLiteral) {
				addError(ctx, `Macro '${macroName}': bindSym expects a single string literal`, node.location.line, node.location.column);
				return node;
			}
			const symName = (cd.arguments[0].data as StringLiteralData).value;
			let bindCtx = ctx;
			const bindDeclPath = regCtx.macroDeclModuleRegistry.get(macroName);
			if (bindDeclPath !== null && bindDeclPath !== "") {
				const mc = lookupModuleCtx(bindDeclPath);
				if (mc !== null) bindCtx = mc;
			}
			const boundSym = lookupSymbol(bindCtx.table, symName);
			if (boundSym === null) {
				addError(ctx, `Macro '${macroName}': bindSym cannot resolve '${symName}' in the macro's module scope`, node.location.line, node.location.column);
				return node;
			}
			if (boundSym.symbolKind !== SymbolKind.Macro) {
				ensureShaped(boundSym, bindCtx);
			}
			if (hasGenericParams(boundSym.symbolType)) {
				addError(ctx, `Macro '${macroName}': bindSym('${symName}') refers to a generic symbol — bind a concrete one (V1)`, node.location.line, node.location.column);
				return node;
			}
			// Bound MACRO: expandMacroInvocation finds the declaring module's
			// registries through modulePath — collectMacro never sets it.
			if (boundSym.symbolKind === SymbolKind.Macro && boundSym.modulePath === "") {
				const bmp = bindCtx.macroDeclModuleRegistry.get(symName);
				boundSym.modulePath = bmp !== null && bmp !== ""
					? bmp
					: (bindDeclPath !== null ? bindDeclPath : "");
			}
			const bloc = node.location;
			const bkeys: string[] = ["kind", "line", "column", "name", "symHandle"];
			const bvalues: Node[] = [
				mkNumber(NodeKind.Identifier as number, bloc),
				mkNumber(bloc.line, bloc),
				mkNumber(bloc.column, bloc),
				mkString(symName, bloc),
				mkNumber(registerBoundSym(boundSym), bloc),
			];
			return createNodeAt(NodeKind.ObjectLiteral, { properties: bvalues, keys: bkeys, keyLocations: [] }, bloc);
		}
		if (cd.callee.kind === NodeKind.Identifier
				&& (cd.callee.data as IdentifierData).name === "getTypeImpl"
				&& cd.arguments.length === 1
				&& cd.arguments[0].kind === NodeKind.Identifier) {
			const typeName = (cd.arguments[0].data as IdentifierData).name;
			let declCtx = ctx;
			const declPath = regCtx.macroDeclModuleRegistry.get(macroName);
			if (declPath !== null && declPath !== "") {
				const mc = lookupModuleCtx(declPath);
				if (mc !== null) declCtx = mc;
			}
			const sym = lookupSymbol(declCtx.table, typeName);
			if (sym === null || sym.symbolType === null) {
				addError(ctx, `Macro '${macroName}': getTypeImpl cannot resolve type '${typeName}' in the macro's module scope`, node.location.line, node.location.column);
				return node;
			}
			// Peel the Ref/Alias wrapper: the caller asked about a TYPE, so hand back
			// its implementation (TypeObject) rather than the Ref<T> that a VALUE of
			// that type would carry. `nodeType` is the opposite case and keeps Ref.
			let t = sym.symbolType;
			let guard = 0;
			while (t !== null && guard < 4
					&& (t.kind === TypeKind.Ref || t.kind === TypeKind.Alias)
					&& t.typeReturn !== null) {
				t = t.typeReturn;
				guard = guard + 1;
			}
			// Assert to Node so flat reads on the spliced literal resolve through the
			// NodeData unique-field-name rule; a bare literal would type as its own
			// anonymous struct and expose only the keys it happens to carry.
			return createNodeAt(NodeKind.TypeAssertion, {
				asExpr: nodeToASTLiteral(mapTypeToAst(t, node.location), node.location),
				asType: "Node",
			}, node.location);
		}
		// getTypeArg() — the explicit <T> written at THIS call site. Resolved in the
		// CALL SITE scope (that is where the user spelled the name), unlike
		// getTypeImpl which resolves in the macro's own module.
		if (cd.callee.kind === NodeKind.Identifier
				&& (cd.callee.data as IdentifierData).name === "getTypeArg"
				&& cd.arguments.length === 0) {
			if (typeArg === "") {
				addError(ctx, `Macro '${macroName}': getTypeArg() needs an explicit type argument at the call site — write ${macroName}<T>(...)`, node.location.line, node.location.column);
				return node;
			}
			if (typeArg.indexOf(",", 0) >= 0) {
				addError(ctx, `Macro '${macroName}': getTypeArg() supports a single type argument, got '${typeArg}'`, node.location.line, node.location.column);
				return node;
			}
			const argSym = lookupSymbol(ctx.table, typeArg);
			if (argSym === null || argSym.symbolType === null) {
				addError(ctx, `Macro '${macroName}': getTypeArg() cannot resolve type '${typeArg}' at the call site`, node.location.line, node.location.column);
				return node;
			}
			let at = argSym.symbolType;
			let aguard = 0;
			while (at !== null && aguard < 4
					&& (at.kind === TypeKind.Ref || at.kind === TypeKind.Alias)
					&& at.typeReturn !== null) {
				at = at.typeReturn;
				aguard = aguard + 1;
			}
			return createNodeAt(NodeKind.TypeAssertion, {
				asExpr: nodeToASTLiteral(mapTypeToAst(at, node.location), node.location),
				asType: "Node",
			}, node.location);
		}
	}
	mapChildren(node, (child: Node): Node => bakeTypeIntrinsics(child, ctx, regCtx, macroName, typeArg));
	return node;
}

// ===== expandMacroInvocation: run a single macro =====

// Exported for eager inline expansion from checkExprPass.ms
// (called when checkCallExpr detects a Macro symbol — see "Phase B+ eager")
interface CompiledMacro {
	vm: RaiserVM;
	funcIdx: number;
}

// Cache keyed on CheckerContext identity so it resets per compilation.
let _compiledMacros: HashMap<string, CompiledMacro> = new HashMap<string, CompiledMacro>();
let _compiledMacrosCtx: CheckerContext = null as unknown as CheckerContext;
// A macro whose body or helpers failed to check is never executed: its bytecode
// is garbage, and running it turns one precise diagnostic into a VM panic or a
// wrong AST. Reported once, then refused silently for every later call site.
let _failedMacros: HashMap<string, boolean> = new HashMap<string, boolean>();

function getOrCompileMacro(ctx: CheckerContext, regCtx: CheckerContext, macroName: string, body: Node, params: string[], typeArg: string): CompiledMacro {
	if (_compiledMacrosCtx !== ctx) {
		_compiledMacros = new HashMap<string, CompiledMacro>();
		_failedMacros = new HashMap<string, boolean>();
		_compiledMacrosCtx = ctx;
	}
	// Cache key carries the declaring module (two modules' same-named macros —
	// reachable via bindSym — must not share a compiled body) and the type
	// argument (getTypeArg() bakes per call site).
	const declKey = regCtx.macroDeclModuleRegistry.get(macroName);
	const cacheKey = (declKey !== null ? declKey : "") + "::"
		+ (typeArg === "" ? macroName : macroName + "<" + typeArg + ">");
	const existing = _compiledMacros.get(cacheKey);
	if (existing !== null) return existing;
	if (_failedMacros.get(cacheKey) !== null) return null as unknown as CompiledMacro;

	// Bake into a CLONE when the call site supplies a type argument: the registry
	// body is shared by every call site, and getTypeArg() resolves per site.
	let workBody = body;
	if (typeArg !== "") workBody = cloneNodeForCheck(body);
	bakeTypeIntrinsics(workBody, ctx, regCtx, macroName, typeArg);
	body = workBody;

	const loc = body.location;
	const wrapperStmts: Node[] = [];

	const fnBodyStmts: Node[] = [];
	const bodyData = body.data as BlockStmtData;
	let si = 0;
	while (si < bodyData.statements.length) {
		const stmt = bodyData.statements[si];
		if (si === bodyData.statements.length - 1 && stmt.kind === NodeKind.ExprStmt) {
			const ed = stmt.data as ExprStmtData;
			fnBodyStmts.push(createNode(NodeKind.ReturnStmt, { argument: cloneNodeForCheck(ed.expr) }, synthToken(loc)));
		} else {
			fnBodyStmts.push(cloneNodeForCheck(stmt));
		}
		si = si + 1;
	}
	const fnBody = createNode(NodeKind.BlockStmt, { statements: fnBodyStmts }, synthToken(loc));
	const declParamTypes = regCtx.macroParamTypesRegistry.get(macroName);
	const paramTypes: string[] = [];
	let pti = 0;
	while (pti < params.length) {
		paramTypes.push(declParamTypes !== null && pti < declParamTypes.length ? declParamTypes[pti] : "");
		pti = pti + 1;
	}
	const emptyDefaults: Node[] = [];
	const macroFn = createNode(NodeKind.FunctionDecl, {
		fnName: "__macroBody",
		params: params,
		fnParamTypes: paramTypes,
		fnBody: fnBody,
		fnFlags: "",
		fnReturnType: "",
		fnDefaults: emptyDefaults,
		nameLocation: loc,
	}, synthToken(loc));
	wrapperStmts.push(macroFn);

	const program = createNode(NodeKind.Program, { programStmts: wrapperStmts }, synthToken(loc));

	const declModulePath = regCtx.macroDeclModuleRegistry.get(macroName);
	setMacroDeclModulePath(declModulePath !== null ? declModulePath : "");
	const result = callMacroEngineCompiler(program, ctx, "__macroBody");
	if (result === null as unknown as EngineMacroResult || result.funcIdx < 0) return null as unknown as CompiledMacro;
	let broken = false;
	if (result.errors !== null && result.errors.length > 0) {
		for (const e of result.errors) {
			if (e.severity !== Severity.Error) continue;
			addError(ctx, `Macro '${macroName}' body: ${e.message}`, e.line, e.column);
			broken = true;
		}
	}
	if (broken) {
		_failedMacros.set(cacheKey, true);
		return null as unknown as CompiledMacro;
	}

	const cm: CompiledMacro = { vm: result.vm, funcIdx: result.funcIdx };
	_compiledMacros.set(cacheKey, cm);
	return cm;
}

export function expandMacroInvocation(node: Node, ctx: CheckerContext, depth: int32): Node {
	const d = node.data as MacroInvocationData;

	// Built-in directives pass through unchanged
	if (isBuiltinDirective(d.macroName)) return node;

	// Bound macro (bindSym): fetch the DECLARING module's registries — the
	// caller never imported this macro, so the user ctx has no entry for it.
	let regCtx = ctx;
	if ((node.flags & NodeFlag.BoundSym) !== 0 && node.resolvedSym !== null
			&& node.resolvedSym.symbolKind === SymbolKind.Macro && node.resolvedSym.modulePath !== "") {
		const bmc = lookupModuleCtx(node.resolvedSym.modulePath);
		if (bmc !== null) regCtx = bmc;
	}
	// Look up the macro body
	// Not a known user macro — leave it alone (could be parsed but undefined)
	const body = regCtx.macroBodyRegistry.get(d.macroName);
	if (body === null) {
		if (regCtx !== ctx) {
			addError(ctx, "bound macro '" + d.macroName + "' has no body registered in its declaring module", node.location.line, node.location.column);
		}
		return node;
	}
	const params = regCtx.macroParamsRegistry.get(d.macroName);
	if (params === null) return node;

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

	// SERIALIZE A3 defer check — mirror of checkExprPass.ms:1663-1672. If any
	// arg's type still contains a GenericParam, the surrounding function isn't
	// monomorphized yet (we're inside a generic body that wasn't instantiated).
	// Don't expand — let monomorphize generate concrete instances; a later
	// expandMacros pass post-mono will fire on those with concrete types.
	// Without this, expanding here would feed Identifier("T") (the generic
	// param's type-AST name) to the macro, which would mis-classify T as an
	// atomic type and emit garbage.
	for (const arg of d.macroArgs) {
		if (arg.nodeType !== null && hasGenericParams(arg.nodeType)) {
			return node;
		}
	}

	const cm = getOrCompileMacro(ctx, regCtx, d.macroName, body, params, node.typeArg);
	if (cm === null as unknown as CompiledMacro) {
		addError(ctx, `Macro '${d.macroName}' evaluator unavailable`, node.location.line, node.location.column);
		return node;
	}
	const vm = cm.vm;
	const marshalArgs: RaiserValue[] = [];
	for (const arg of d.macroArgs) {
		const av = nodeToValue(stripMacroArgWrappers(arg), vm.objectHeap, vm.arrayHeap);
		marshalArgs.push(av);
	}
	const resultVal = vmCallFunction(vm, cm.funcIdx, marshalArgs);

	let vmCtx: RaiserContext | null = {
		mod: vm.mod,
		hasModule: true,
		lastResult: resultVal,
		lastOutput: vm.output,
		arrayHeap: vm.arrayHeap,
		objectHeap: vm.objectHeap,
		lastError: vm.error,
		gcMode: vm.gcMode,
	};

	// Check for VM-level errors (instruction budget, division by zero, etc.)
	if (vmCtx.lastError !== "") {
		addError(ctx, `Macro '${d.macroName}' failed: ${vmCtx.lastError}`,
			node.location.line, node.location.column);
		clearObjectHeap(vmCtx.objectHeap);
		clearArrayHeap(vmCtx.arrayHeap);
		return node;
	}

	// Check for compile-time error sentinel.
	// error("msg") → { __compileError: 1, message: "msg" }
	// error("msg", node) → { __compileError: 1, message: "msg", line: N, column: N }
	const lastVal = vmCtx.lastResult;
	if (lastVal.kind === RaiserValueKind.Object) {
		const errFlag = heapObjectGetField(vmCtx.objectHeap, lastVal.intVal, "__compileError");
		if (errFlag.kind === RaiserValueKind.Int && errFlag.intVal === 1) {
			const errMsg = heapObjectGetField(vmCtx.objectHeap, lastVal.intVal, "message");
			const msg = errMsg.kind === RaiserValueKind.String ? errMsg.strVal : "compile error in macro";
			// 2-arg form: use the input node's location if provided.
			// Supports both point (line, column) and range (+ endLine, endColumn).
			const errLine = heapObjectGetField(vmCtx.objectHeap, lastVal.intVal, "line");
			const errCol = heapObjectGetField(vmCtx.objectHeap, lastVal.intVal, "column");
			const errEndLine = heapObjectGetField(vmCtx.objectHeap, lastVal.intVal, "endLine");
			const errEndCol = heapObjectGetField(vmCtx.objectHeap, lastVal.intVal, "endColumn");
			const diagLine = errLine.kind === RaiserValueKind.Int ? errLine.intVal : (errLine.kind === RaiserValueKind.Float ? errLine.floatVal as int32 : node.location.line);
			const diagCol = errCol.kind === RaiserValueKind.Int ? errCol.intVal : (errCol.kind === RaiserValueKind.Float ? errCol.floatVal as int32 : node.location.column);
			const hasEndLine = errEndLine.kind === RaiserValueKind.Int || errEndLine.kind === RaiserValueKind.Float;
			const hasEndCol = errEndCol.kind === RaiserValueKind.Int || errEndCol.kind === RaiserValueKind.Float;
			if (hasEndLine || hasEndCol) {
				const diagEndLine = hasEndLine ? (errEndLine.kind === RaiserValueKind.Int ? errEndLine.intVal : errEndLine.floatVal as int32) : diagLine;
				const diagEndCol = hasEndCol ? (errEndCol.kind === RaiserValueKind.Int ? errEndCol.intVal : errEndCol.floatVal as int32) : diagCol + 1;
				addErrorFullRange(ctx, `Macro '${d.macroName}': ${msg}`, diagLine, diagCol, diagEndLine, diagEndCol);
			} else {
				addError(ctx, `Macro '${d.macroName}': ${msg}`, diagLine, diagCol);
			}
			clearObjectHeap(vmCtx.objectHeap);
			clearArrayHeap(vmCtx.arrayHeap);
			return node;
		}
	}
	// Check for compile-time warnings in Raiser output.
	// warning("msg") → "__MACRO_WARN__:msg"
	// warning("msg", node) → "__MACRO_WARN__:msg\tline\tcol"
	if (vmCtx.lastOutput !== "") {
		let warnStart = vmCtx.lastOutput.indexOf("__MACRO_WARN__:", 0);
		while (warnStart >= 0) {
			let warnEnd = vmCtx.lastOutput.indexOf("\n", warnStart);
			if (warnEnd < 0) warnEnd = vmCtx.lastOutput.length;
			const warnPayload = vmCtx.lastOutput.slice(warnStart + 15, warnEnd);
			// Check for tab-separated location: "msg\tline\tcol"
			const tabIdx = warnPayload.indexOf("\t", 0);
			let warnMsg = warnPayload;
			let warnLine = node.location.line;
			let warnCol = node.location.column;
			if (tabIdx >= 0) {
				warnMsg = warnPayload.slice(0, tabIdx);
				const locPart = warnPayload.slice(tabIdx + 1, warnPayload.length);
				const tab2 = locPart.indexOf("\t", 0);
				if (tab2 >= 0) {
					warnLine = parseIntStr(locPart.slice(0, tab2)) as int32;
					warnCol = parseIntStr(locPart.slice(tab2 + 1, locPart.length)) as int32;
					if (warnLine <= 0) warnLine = node.location.line;
					if (warnCol <= 0) warnCol = node.location.column;
				}
			}
			addWarning(ctx, `Macro '${d.macroName}': ${warnMsg}`, warnLine, warnCol);
			warnStart = vmCtx.lastOutput.indexOf("__MACRO_WARN__:", warnEnd);
		}
	}

	// Deserialize result
	let result = valueToNode(vmCtx.lastResult, vmCtx.objectHeap, vmCtx.arrayHeap, node.location);

	// Reclaim VM heaps
	clearObjectHeap(vmCtx.objectHeap);
	clearArrayHeap(vmCtx.arrayHeap);
	vmCtx = null;

	// Deserialized result has fresh CallExpr nodes for any nested
	// macro references — the checker's CallExpr→MacroInvocation rewrite at
	// checkExprPass.ms:1652 only ran on the original AST, not on this freshly
	// reconstructed tree. Walk the result and rewrite so the re-walk loop
	// below picks them up.
	//
	// Only apply in POST-MONO context. ctx.macroExpansionDepth > 0 indicates
	// we're inside the checker's eager-expansion path (incremented in
	// checkExprPass before calling us). In eager path, the checker's
	// re-check already re-traverses the result and converts
	// CallExpr-of-macro to MacroInvocation via its normal flow — applying
	// the rewrite here too would double-expand nested macros.
	if (ctx.macroExpansionDepth === 0) {
		result = rewriteCallExprToMacroInvocation(result, ctx);
	}

	// Re-expand if result contains more macros (depth-limited)
	if (depth < 16 && hasUserMacroInvocation(result, ctx)) {
		result = walkExpand(result, ctx, depth + 1);
	}

	return result;
}

// ===== walkExpand: recursive AST walker =====

// Walks an array of nodes, replacing each with its expansion in place.
function walkExpandArray(arr: Node[], ctx: CheckerContext, depth: int32): void {
	// SERIALIZE A2: macros may return NodeKind.SpliceMany to emit multiple
	// statements at the parent position. We splice spliceNodes into the array
	// (replacing the SpliceMany element). Other returns replace 1:1 as before.
	//
	// Strategy: 2-pass — walk + tag positions on first pass; rebuild flat
	// array on second pass only if any SpliceMany seen. No-splice case stays
	// O(n) with no extra allocation.
	//
	// V1 limit: ONE-LEVEL flatten. If a spliceNode is itself SpliceMany,
	// it stays as-is (codegen will likely crash). Macro authors must emit
	// flat SpliceMany. V2 may add recursive flatten.
	let needsRebuild = false;
	let i = 0;
	while (i < arr.length) {
		const expanded = walkExpand(arr[i], ctx, depth);
		if (expanded.kind === NodeKind.SpliceMany) {
			needsRebuild = true;
		}
		arr[i] = expanded;
		i = i + 1;
	}
	if (!needsRebuild) return;
	// Rebuild flat array — flatten any SpliceMany entries.
	const flat: Node[] = [];
	for (const item of arr) {
		if (item.kind === NodeKind.SpliceMany) {
			const sd = item.data as SpliceManyData;
			for (const child of sd.spliceNodes) flat.push(child);
		} else {
			flat.push(item);
		}
	}
	arr.length = 0;
	for (const n of flat) arr.push(n);
}

// In-place mutation strategy: for non-MacroInvocation nodes, recursively expand
// children by mutating the node.data fields directly. This is safe because the
// macro expansion pass owns the AST at this point — earlier passes have already
// produced it, and later passes consume it. Avoids the field-name explosion of
// rebuilding via createNode for every NodeKind.
function walkExpand(node: Node, ctx: CheckerContext, depth: int32): Node {
	if (node === null) return node;

	return match (node.kind) {
		NodeKind.MacroInvocation => expandMacroInvocation(node, ctx, depth),

		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			d.initializer = walkExpand(d.initializer, ctx, depth);
			return node;
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			d.expr = walkExpand(d.expr, ctx, depth);
			return node;
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			d.argument = walkExpand(d.argument, ctx, depth);
			return node;
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			d.throwArg = walkExpand(d.throwArg, ctx, depth);
			return node;
		},
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			d.deferExpr = walkExpand(d.deferExpr, ctx, depth);
			return node;
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			walkExpandArray(d.statements, ctx, depth);
			return node;
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = walkExpand(d.condition, ctx, depth);
			d.consequent = walkExpand(d.consequent, ctx, depth);
			d.alternate = walkExpand(d.alternate, ctx, depth);
			return node;
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = walkExpand(d.whileCondition, ctx, depth);
			d.whileBody = walkExpand(d.whileBody, ctx, depth);
			return node;
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doBody = walkExpand(d.doBody, ctx, depth);
			d.doCondition = walkExpand(d.doCondition, ctx, depth);
			return node;
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			d.forInit = walkExpand(d.forInit, ctx, depth);
			d.forCondition = walkExpand(d.forCondition, ctx, depth);
			d.forUpdate = walkExpand(d.forUpdate, ctx, depth);
			d.forBody = walkExpand(d.forBody, ctx, depth);
			return node;
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			d.forOfIterable = walkExpand(d.forOfIterable, ctx, depth);
			d.forOfBody = walkExpand(d.forOfBody, ctx, depth);
			return node;
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			d.forInObject = walkExpand(d.forInObject, ctx, depth);
			d.forInBody = walkExpand(d.forInBody, ctx, depth);
			return node;
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			d.switchDisc = walkExpand(d.switchDisc, ctx, depth);
			walkExpandArray(d.switchCases, ctx, depth);
			return node;
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			walkExpandArray(d.caseTests, ctx, depth);
			walkExpandArray(d.caseStmts, ctx, depth);
			return node;
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			d.matchStmtDisc = walkExpand(d.matchStmtDisc, ctx, depth);
			walkExpandArray(d.matchStmtCases, ctx, depth);
			return node;
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			d.matchDisc = walkExpand(d.matchDisc, ctx, depth);
			walkExpandArray(d.matchCases, ctx, depth);
			return node;
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			walkExpandArray(d.casePatterns, ctx, depth);
			d.caseGuard = walkExpand(d.caseGuard, ctx, depth);
			d.caseBody = walkExpand(d.caseBody, ctx, depth);
			return node;
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			d.tryBody = walkExpand(d.tryBody, ctx, depth);
			d.catchBody = walkExpand(d.catchBody, ctx, depth);
			d.finallyBody = walkExpand(d.finallyBody, ctx, depth);
			return node;
		},

		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.left = walkExpand(d.left, ctx, depth);
			d.right = walkExpand(d.right, ctx, depth);
			return node;
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = walkExpand(d.operand, ctx, depth);
			return node;
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			d.callee = walkExpand(d.callee, ctx, depth);
			walkExpandArray(d.arguments, ctx, depth);
			return node;
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			d.object = walkExpand(d.object, ctx, depth);
			return node;
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			d.array = walkExpand(d.array, ctx, depth);
			d.index = walkExpand(d.index, ctx, depth);
			return node;
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = walkExpand(d.ternaryCondition, ctx, depth);
			d.ternaryConsequent = walkExpand(d.ternaryConsequent, ctx, depth);
			d.ternaryAlternate = walkExpand(d.ternaryAlternate, ctx, depth);
			return node;
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			walkExpandArray(d.properties, ctx, depth);
			return node;
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			walkExpandArray(d.elements, ctx, depth);
			return node;
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			d.arrowBody = walkExpand(d.arrowBody, ctx, depth);
			return node;
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			d.funcExprBody = walkExpand(d.funcExprBody, ctx, depth);
			return node;
		},

		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			d.fnBody = walkExpand(d.fnBody, ctx, depth);
			return node;
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			d.exportedDecl = walkExpand(d.exportedDecl, ctx, depth);
			return node;
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			walkExpandArray(d.classBody, ctx, depth);
			return node;
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			d.methodBody = walkExpand(d.methodBody, ctx, depth);
			return node;
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			d.ctorBody = walkExpand(d.ctorBody, ctx, depth);
			return node;
		},
		NodeKind.PropertyDecl => {
			const d = node.data as PropertyDeclData;
			d.propInitializer = walkExpand(d.propInitializer, ctx, depth);
			return node;
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkExpandArray(d.decorators, ctx, depth);
			d.decoratedNode = walkExpand(d.decoratedNode, ctx, depth);
			return node;
		},
		NodeKind.Program => {
			const d = node.data as ProgramData;
			walkExpandArray(d.programStmts, ctx, depth);
			return node;
		},

		_ => node,
	};
}

// ===== Public API =====

export function expandMacros(program: Node, ctx: CheckerContext): Node {
	if (!hasUserMacroInvocation(program, ctx)) return program;
	return walkExpand(program, ctx, 0);
}

// Register expandMacroInvocation as a callback so checkExprPass can invoke it
// without importing this module directly (breaks the checker ↔ compiler/meta cycle).
import { registerExpandMacroInvocation } from "../../checker/checkerCallbacks";
registerExpandMacroInvocation(expandMacroInvocation);

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
		methodIsStatic: false, methodFlags: "", methodVisibility: "", methodReturnType: "",
		methodDefaults: [], nativeName: "", nameLocation: loc,
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
		interfaceName: "X", interfaceFields: [], interfaceFieldTypes: [], interfaceExtends: [] as string[], nameLocation: loc,
	}, synthToken(loc));
	const dec = createNode(NodeKind.DecoratedDecl, {
		decorators: [inv], decoratedNode: inner,
	}, synthToken(loc));
	assert hasUserMacroInvocation(dec, ctx);
}

// ===== A2 — walkExpandArray SpliceMany splice mechanics =====

test "walkExpandArray flattens SpliceMany returned at array position" {
	const loc = makeLoc(1, 0);
	// Build: [VarDecl, SpliceMany([VarDecl_a, VarDecl_b]), ReturnStmt]
	// After walk: [VarDecl, VarDecl_a, VarDecl_b, ReturnStmt]
	const v0 = createNode(NodeKind.VariableDecl, {
		declName: "v0", declType: "", initializer: mkNumber(0, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const va = createNode(NodeKind.VariableDecl, {
		declName: "va", declType: "", initializer: mkNumber(1, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const vb = createNode(NodeKind.VariableDecl, {
		declName: "vb", declType: "", initializer: mkNumber(2, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const splice = createNodeAt(NodeKind.SpliceMany, { spliceNodes: [va, vb] }, loc);
	const ret = createNode(NodeKind.ReturnStmt, { argument: mkNumber(0, loc) }, synthToken(loc));
	const arr: Node[] = [v0, splice, ret];
	const ctx = createContext();
	walkExpandArray(arr, ctx, 0);
	assert arr.length === 4;
	assert (arr[0].data as VariableDeclData).declName === "v0";
	assert (arr[1].data as VariableDeclData).declName === "va";
	assert (arr[2].data as VariableDeclData).declName === "vb";
	assert arr[3].kind === NodeKind.ReturnStmt;
}

test "walkExpandArray flattens empty SpliceMany (removes the slot)" {
	const loc = makeLoc(1, 0);
	const v0 = createNode(NodeKind.VariableDecl, {
		declName: "v0", declType: "", initializer: mkNumber(0, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const splice = createNodeAt(NodeKind.SpliceMany, { spliceNodes: [] }, loc);
	const v1 = createNode(NodeKind.VariableDecl, {
		declName: "v1", declType: "", initializer: mkNumber(1, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const arr: Node[] = [v0, splice, v1];
	const ctx = createContext();
	walkExpandArray(arr, ctx, 0);
	assert arr.length === 2;
	assert (arr[0].data as VariableDeclData).declName === "v0";
	assert (arr[1].data as VariableDeclData).declName === "v1";
}

test "walkExpandArray no-op when no SpliceMany present" {
	const loc = makeLoc(1, 0);
	const v0 = createNode(NodeKind.VariableDecl, {
		declName: "v0", declType: "", initializer: mkNumber(0, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const v1 = createNode(NodeKind.VariableDecl, {
		declName: "v1", declType: "", initializer: mkNumber(1, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const arr: Node[] = [v0, v1];
	const ctx = createContext();
	walkExpandArray(arr, ctx, 0);
	assert arr.length === 2;
	assert (arr[0].data as VariableDeclData).declName === "v0";
	assert (arr[1].data as VariableDeclData).declName === "v1";
}

// Regression: preprocessNode rewrites `NodeKind.X` member access to integer
// ordinals throughout the macro body. Previously had its own ad-hoc walker
// that missed ForOfStmt/SwitchStmt/MatchExpr etc. — `kind: NodeKind.NumberLiteral`
// inside `for (const f of fields) { ... }` stayed as MemberExpr at runtime,
// returning nil, so heap objects had no `kind` field and valueToNode fell back
// to deserializeObjectLiteral. Now uses walker.ms walkNode (single source of
// truth). This test verifies preprocessNode descends into a ForOfStmt body.
test "preprocessNode rewrites NodeKind.X inside ForOfStmt body" {
	const loc = makeLoc(1, 1);
	// Build: for (const f of fields) { let x = NodeKind.NumberLiteral; }
	// Using literal ObjectLiteral construction to avoid parser dependency.
	const memberExpr = createNodeAt(NodeKind.MemberExpr, {
		object: createNodeAt(NodeKind.Identifier, { name: "NodeKind" }, loc),
		property: "NumberLiteral",
		isOptional: false,
	}, loc);
	const innerDecl = createNodeAt(NodeKind.VariableDecl, {
		declName: "x", declType: "", initializer: memberExpr,
		declKind: DeclKind.Let, nameLocation: loc,
	}, loc);
	const body = createNodeAt(NodeKind.BlockStmt, { statements: [innerDecl] }, loc);
	const fields = createNodeAt(NodeKind.Identifier, { name: "fields" }, loc);
	const forOf = createNodeAt(NodeKind.ForOfStmt, {
		forOfBinding: "f", forOfIsConst: true,
		forOfIterable: fields, forOfBody: body,
		forOfPattern: null as unknown as Node, bindingLocation: loc,
	}, loc);

	preprocessMacroBody(forOf);

	// After preprocessing, the inner VariableDecl's initializer should be a
	// NumberLiteral with value === NodeKind.NumberLiteral ordinal (=0), not a
	// MemberExpr. If preprocessNode still skipped ForOfStmt body, this would
	// remain a MemberExpr and the assertion fails.
	const rewrittenInit = (innerDecl.data as VariableDeclData).initializer;
	assert rewrittenInit.kind === NodeKind.NumberLiteral;
	assert (rewrittenInit.data as NumberLiteralData).value === (NodeKind.NumberLiteral as number);
}

