// Transform Utilities — node-building helpers for AST transforms
// Each helper wraps createNode with the correct NodeKind and data shape.

import { Token, TokenKind, createToken } from "../lexer/token";
import {
	Node, NodeKind, DeclKind, SourceLocation, createNode, makeLoc, Symbol,
	BlockStmtData, VariableDeclData, IfStmtData, WhileStmtData,
	TryCatchStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	CallExprData, MemberExprData, IdentifierData,
} from "../ast/node";
import {
	Type, TypeKind, createFunction, createStruct, createTypeRef, createArray,
	numberType, stringType, booleanType, voidType, nullType, unknownType, getSysType,
} from "../checker/types";
import { TransformContext, freshTemp, NameSet, nameSetAdd } from "./context";

// Create a synthetic token from a source location (for transform-generated nodes)
export function syntheticToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

// ===== Naming Conventions =====

// Canonical name for auto-generated enum-to-string function (e.g., "Color_toString").
// Used by enumToStringLower (generation), builtinLower + debugLower (call site rewriting).
export function enumToStringName(enumName: string): string {
	return enumName + "_toString";
}

// ===== Literal Builders =====

export function makeIdent(identName: string, loc: SourceLocation): Node {
	return createNode(NodeKind.Identifier, { name: identName }, syntheticToken(loc));
}

// Typed variant: creates an identifier with a known Type (for synthetic temps)
export function makeTypedIdent(identName: string, t: Type, loc: SourceLocation): Node {
	const n = createNode(NodeKind.Identifier, { name: identName }, syntheticToken(loc));
	if (t !== null) { n.nodeType = t; }
	return n;
}

// Decisive variant: creates an identifier already linked to a symbol
export function makeIdentResolved(sym: Symbol, loc: SourceLocation): Node {
	const n = createNode(NodeKind.Identifier, { name: sym.name }, syntheticToken(loc));
	n.resolvedSym = sym;
	n.nodeType = sym.symbolType;
	return n;
}

export function makeNull(loc: SourceLocation): Node {
	const n = createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, syntheticToken(loc));
	n.nodeType = nullType();
	return n;
}

export function makeNumber(val: number, loc: SourceLocation): Node {
	const n = createNode(NodeKind.NumberLiteral, { value: val }, syntheticToken(loc));
	n.nodeType = numberType();
	return n;
}

export function makeString(val: string, loc: SourceLocation): Node {
	const n = createNode(NodeKind.StringLiteral, { value: val }, syntheticToken(loc));
	n.nodeType = stringType();
	return n;
}

export function makeBool(val: boolean, loc: SourceLocation): Node {
	const n = createNode(NodeKind.BooleanLiteral, { boolValue: val }, syntheticToken(loc));
	n.nodeType = booleanType();
	return n;
}

// ===== Statement Builders =====

export function makeBlock(stmts: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.BlockStmt, { statements: stmts }, syntheticToken(loc));
}

export function makeVarDecl(varName: string, init: Node, declKind: DeclKind, loc: SourceLocation): Node {
	const n = createNode(NodeKind.VariableDecl, { declName: varName, declType: "", initializer: init, declKind, nameLocation: loc }, syntheticToken(loc));
	if (init !== null && init.nodeType !== null) {
		n.nodeType = init.nodeType;
	}
	return n;
}

export function makeExprStmt(exprNode: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ExprStmt, { expr: exprNode }, syntheticToken(loc));
}

export function makeReturn(arg: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.ReturnStmt, { argument: arg }, syntheticToken(loc));
}

export function makeIf(cond: Node, thenBranch: Node, elseBranch: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.IfStmt, { condition: cond, consequent: thenBranch, alternate: elseBranch }, syntheticToken(loc));
}

export function makeWhile(cond: Node, body: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.WhileStmt, { whileCondition: cond, whileBody: body }, syntheticToken(loc));
}

export function makeTryCatch(tryBody: Node, catchName: string, catchBody: Node, finallyBody: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.TryCatchStmt, { tryBody, catchName, catchBody, finallyBody, catchBindingLocation: makeLoc(0, 0) }, syntheticToken(loc));
}

export function makeContinue(loc: SourceLocation): Node {
	return createNode(NodeKind.ContinueStmt, { continueLabel: "" }, syntheticToken(loc));
}

// ===== Expression Builders =====

export function makeBinary(leftNode: Node, op: string, rightNode: Node, loc: SourceLocation): Node {
	const n = createNode(NodeKind.BinaryExpr, { operator: op, left: leftNode, right: rightNode }, syntheticToken(loc));
	if (op === "===" || op === "!==" || op === "==" || op === "!=" || op === "<" || op === ">" || op === "<=" || op === ">=" || op === "||" || op === "&&") {
		n.nodeType = booleanType();
	} else if (leftNode !== null && leftNode.nodeType !== null) {
		n.nodeType = leftNode.nodeType;
	}
	return n;
}

export function makeMoveExpr(inner: Node, loc: SourceLocation): Node {
	return createNode(NodeKind.MoveExpr, { moveArg: inner }, syntheticToken(loc));
}

export function makeUnary(op: string, arg: Node, loc: SourceLocation): Node {
	const n = createNode(NodeKind.UnaryExpr, { unaryOp: op, operand: arg }, syntheticToken(loc));
	if (op === "!") {
		n.nodeType = booleanType();
	} else if (op === "typeof") {
		n.nodeType = stringType();
	} else if (arg !== null && arg.nodeType !== null) {
		n.nodeType = arg.nodeType;
	}
	return n;
}

export function makeCall(calleeNode: Node, args: Node[], loc: SourceLocation): Node {
	const n = createNode(NodeKind.CallExpr, { callee: calleeNode, arguments: args, isDirectCall: true, resolvedOverloadIdx: -1 }, syntheticToken(loc));
	if (calleeNode !== null) {
		if (calleeNode.resolvedSym !== null) {
			n.resolvedSym = calleeNode.resolvedSym;
		}
		if (calleeNode.nodeType !== null && calleeNode.nodeType.kind === TypeKind.Function) {
			if (calleeNode.nodeType.typeReturn !== null) {
				n.nodeType = calleeNode.nodeType.typeReturn;
			}
		}
	}
	return n;
}

// Decisive variant: creates a call with an explicit resolved symbol
export function makeCallResolved(calleeNode: Node, args: Node[], sym: Symbol, loc: SourceLocation): Node {
	const n = createNode(NodeKind.CallExpr, { callee: calleeNode, arguments: args, isDirectCall: true, resolvedOverloadIdx: -1 }, syntheticToken(loc));
	n.resolvedSym = sym;
	if (sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) {
		n.nodeType = sym.symbolType.typeReturn;
	}
	return n;
}

export function makeMember(obj: Node, prop: string, loc: SourceLocation): Node {
	const n = createNode(NodeKind.MemberExpr, { object: obj, property: prop, isOptional: false }, syntheticToken(loc));
	if (obj !== null && obj.nodeType !== null) {
		if ((obj.nodeType.kind === TypeKind.Array || obj.nodeType.kind === TypeKind.String) && prop === "length") {
			n.nodeType = numberType();
		} else if (obj.nodeType.kind === TypeKind.Result) {
			if (prop === "ok") { n.nodeType = booleanType(); }
			else if (prop === "value" && obj.nodeType.typeReturn !== null) { n.nodeType = obj.nodeType.typeReturn; }
			else if (prop === "error" && obj.nodeType.typeExtra !== null) { n.nodeType = obj.nodeType.typeExtra; }
		} else if (obj.nodeType.kind === TypeKind.Struct) {
			let pi = 0;
			while (pi < obj.nodeType.typeNames.length) {
				if (obj.nodeType.typeNames[pi] === prop) {
					n.nodeType = obj.nodeType.typeChildren[pi];
					pi = obj.nodeType.typeNames.length;
				}
				pi = pi + 1;
			}
		}
	}
	return n;
}

export function makeConditional(cond: Node, cons: Node, alt: Node, loc: SourceLocation): Node {
	const n = createNode(NodeKind.ConditionalExpr, { ternaryCondition: cond, ternaryConsequent: cons, ternaryAlternate: alt }, syntheticToken(loc));
	if (cons !== null && cons.nodeType !== null) {
		n.nodeType = cons.nodeType;
	} else if (alt !== null && alt.nodeType !== null) {
		n.nodeType = alt.nodeType;
	}
	return n;
}

export function makeAssign(leftNode: Node, rightNode: Node, loc: SourceLocation): Node {
	const n = createNode(NodeKind.BinaryExpr, { operator: "=", left: leftNode, right: rightNode }, syntheticToken(loc));
	if (rightNode !== null && rightNode.nodeType !== null) {
		n.nodeType = rightNode.nodeType;
	}
	return n;
}

export function makeArrayAccess(obj: Node, idx: Node, loc: SourceLocation): Node {
	const n = createNode(NodeKind.ArrayAccess, { array: obj, index: idx }, syntheticToken(loc));
	if (obj !== null && obj.nodeType !== null && obj.nodeType.kind === TypeKind.Array) {
		if (obj.nodeType.typeReturn !== null) {
			n.nodeType = obj.nodeType.typeReturn;
		}
	}
	return n;
}

export function makeSwitch(disc: Node, cases: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.SwitchStmt, { switchDisc: disc, switchCases: cases }, syntheticToken(loc));
}

export function makeSwitchCase(tests: Node[], stmts: Node[], isDefault: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.SwitchCase, { caseTests: tests, caseStmts: stmts, isDefault }, syntheticToken(loc));
}

// ===== Declaration Builders =====

export function makeFnDecl(name: string, fnParams: string[], paramTypes: string[], body: Node, flags: string, returnType: string, loc: SourceLocation): Node {
	const emptyDefaults: Node[] = [];
	const n = createNode(NodeKind.FunctionDecl, {
		fnName: name, params: fnParams, fnParamTypes: paramTypes,
		fnBody: body, fnFlags: flags, fnReturnType: returnType,
		fnDefaults: emptyDefaults, nativeName: "", nameLocation: loc,
	}, syntheticToken(loc));
	// Build Type from string annotations for codegen (Implementation parity)
	const resolvedParams: Type[] = [];
	for (let i = 0; i < paramTypes.length; i += 1) {
		resolvedParams.push(resolveSimpleTypeStr(paramTypes[i]));
	}
	const resolvedRet = resolveSimpleTypeStr(returnType);
	n.nodeType = createFunction(resolvedParams, fnParams, resolvedRet);
	return n;
}

export function makeInterfaceDecl(name: string, fields: string[], fieldTypes: string[], loc: SourceLocation): Node {
	const n = createNode(NodeKind.InterfaceDecl, {
		interfaceName: name, interfaceFields: fields, interfaceFieldTypes: fieldTypes,
		nameLocation: loc,
	}, syntheticToken(loc));
	// Build Type for codegen (Implementation parity)
	const resolvedFieldTypes: Type[] = [];
	for (let i = 0; i < fieldTypes.length; i += 1) {
		resolvedFieldTypes.push(resolveSimpleTypeStr(fieldTypes[i]));
	}
	n.nodeType = createStruct(name, fields, resolvedFieldTypes, true);
	return n;
}

// Resolve simple type annotation strings to Type objects for transform-generated nodes.
// Handles primitives, named types, and array annotations ("Foo[]", "Foo [ ]").
// Complex types (Result<T,E>, Map<K,V>) remain as TypeReference — codegen resolves those.
function resolveSimpleTypeStr(annotation: string): Type {
	if (annotation === "") return unknownType();
	if (annotation === "void*") return unknownType();  // void* → Unknown → "void*" in codegen
	// Handle array annotations: "Foo[]", "Foo [ ]" (parser joins tokens with spaces)
	// Strip trailing whitespace-surrounded brackets to get element type
	const stripped = stripArraySuffix(annotation);
	if (stripped !== "") {
		return createArray(resolveSimpleTypeStr(stripped));
	}
	return match (annotation) {
		"number" | "float64" => numberType(),
		"string" => stringType(),
		"boolean" => booleanType(),
		"void" => voidType(),
		"null" => nullType(),
		"int8" => getSysType(TypeKind.Int8),
		"int16" => getSysType(TypeKind.Int16),
		"int32" => getSysType(TypeKind.Int32),
		"int64" => getSysType(TypeKind.Int64),
		"uint8" => getSysType(TypeKind.Uint8),
		"uint16" => getSysType(TypeKind.Uint16),
		"uint32" => getSysType(TypeKind.Uint32),
		"uint64" => getSysType(TypeKind.Uint64),
		"float32" => getSysType(TypeKind.Float32),
		_ => createTypeRef(annotation),
	};
}

// Strip trailing "[]" or " [ ]" (parser collectTokenText joins tokens with spaces)
// Returns element type string, or "" if not an array annotation.
function stripArraySuffix(annotation: string): string {
	const len = annotation.length;
	if (len < 2) return "";
	// Check for "[]" at end (from typeToEnvStr: "string[]")
	if (annotation.charAt(len - 1) === "]" && annotation.charAt(len - 2) === "[") {
		return annotation.slice(0, len - 2);
	}
	// Check for " [ ]" at end (from parser collectTokenText: "string [ ]")
	if (len >= 5 && annotation.charAt(len - 1) === "]" && annotation.charAt(len - 2) === " "
		&& annotation.charAt(len - 3) === "[" && annotation.charAt(len - 4) === " ") {
		return annotation.slice(0, len - 4);
	}
	return "";
}

export function makeObjectLiteral(keys: string[], values: Node[], loc: SourceLocation): Node {
	return createNode(NodeKind.ObjectLiteral, { properties: values, keys }, syntheticToken(loc));
}

// Typed variant: creates an ObjectLiteral with a known Type (standard object construction parity)
export function makeTypedObjectLiteral(keys: string[], values: Node[], t: Type, loc: SourceLocation): Node {
	const n = createNode(NodeKind.ObjectLiteral, { properties: values, keys }, syntheticToken(loc));
	if (t !== null) { n.nodeType = t; }
	return n;
}

export function makeHiddenAddr(inner: Node, loc: SourceLocation): Node {
	const n = createNode(NodeKind.HiddenAddr, { expr: inner }, syntheticToken(loc));
	if (inner !== null) n.nodeType = inner.nodeType;
	return n;
}

export function makeHiddenDeref(inner: Node, loc: SourceLocation): Node {
	const n = createNode(NodeKind.HiddenDeref, { expr: inner }, syntheticToken(loc));
	if (inner !== null && inner.nodeType !== null) {
		// Deref of Ref<T>/Ptr<T>/Borrow<T> → type is T (Reference: strips through all pointer types)
		const k = inner.nodeType.kind;
		if ((k === TypeKind.Ptr || k === TypeKind.Ref || k === TypeKind.Borrow) && inner.nodeType.typeReturn !== null) {
			n.nodeType = inner.nodeType.typeReturn;
		} else {
			n.nodeType = inner.nodeType;
		}
	}
	return n;
}

export function makeHiddenStdConv(inner: Node, targetType: Type, loc: SourceLocation): Node {
	const n = createNode(NodeKind.HiddenStdConv, { convExpr: inner, convType: targetType }, syntheticToken(loc));
	n.nodeType = targetType;
	return n;
}

export function makeHiddenSubConv(inner: Node, targetType: Type, loc: SourceLocation): Node {
	const n = createNode(NodeKind.HiddenSubConv, { convExpr: inner, convType: targetType }, syntheticToken(loc));
	n.nodeType = targetType;
	return n;
}

// ===== Declaration Collection =====
// Collect variable declaration names in a function body. Stops at nested functions.
// varOnly=true: only DeclKind.Var (for varHoist). varOnly=false: all decls (for generatorLower).
// Handles: BlockStmt, IfStmt, WhileStmt, TryCatchStmt, DoWhileStmt, SwitchStmt/SwitchCase.

export function collectDeclNames(node: Node, ns: NameSet, varOnly: boolean): void {
	match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (!varOnly || d.declKind === DeclKind.Var) {
				nameSetAdd(ns, d.declName);
			}
			collectDeclNames(d.initializer, ns, varOnly);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				collectDeclNames(d.statements[i], ns, varOnly);
				i += 1;
			}
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			collectDeclNames(d.consequent, ns, varOnly);
			collectDeclNames(d.alternate, ns, varOnly);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			collectDeclNames(d.whileBody, ns, varOnly);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			collectDeclNames(d.tryBody, ns, varOnly);
			collectDeclNames(d.catchBody, ns, varOnly);
			collectDeclNames(d.finallyBody, ns, varOnly);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			collectDeclNames(d.doBody, ns, varOnly);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			let si = 0;
			while (si < d.switchCases.length) {
				collectDeclNames(d.switchCases[si], ns, varOnly);
				si += 1;
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			let ci = 0;
			while (ci < d.caseStmts.length) {
				collectDeclNames(d.caseStmts[ci], ns, varOnly);
				ci += 1;
			}
		},
		_ => {},
	};
}

// ===== DeclKind Helpers =====

// Convert boolean isConst flag → DeclKind enum (for AST nodes that still use boolean flags)
export function boolToDeclKind(isConst: boolean): DeclKind {
	return match (isConst) { true => DeclKind.Const, _ => DeclKind.Let };
}

// ===== Helpers =====

// Capture an expression into a temp variable to prevent double-evaluation.
// Returns { decl: const $tmp_N = expr, ref: $tmp_N identifier }.
// Follows the reference evalOnce pattern.
export function evalOnce(expr: Node, ctx: TransformContext, loc: SourceLocation): { decl: Node, ref: Node } {
	const name = freshTemp(ctx, "tmp");
	const decl = makeVarDecl(name, expr, DeclKind.Const, loc);
	const ref = makeIdent(name, loc);
	if (expr !== null && expr.nodeType !== null) {
		ref.nodeType = expr.nodeType;
	}
	return { decl, ref };
}

// Extract statements from a body node (block → its stmts, single stmt → [stmt])
export function extractBodyStmts(body: Node): Node[] {
	const result: Node[] = [];
	if (body.kind === NodeKind.BlockStmt) {
		const bd = body.data as BlockStmtData;
		for (const stmt of bd.statements) {
			result.push(stmt);
		}
	} else {
		result.push(body);
	}
	return result;
}
