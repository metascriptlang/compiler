// C Codegen — Expression Emission
//
// genExpr returns a C code snippet string for any expression node.
// genExprToLoc fills a CLoc dest (for statement-level assignment).
//
// Follows Nim's ccgexprs.nim dest carrier pattern, adapted for
// MetaScript value-type interfaces (CLoc passed by value → use return).

import {
	Node, NodeKind, NF_CLOSURE,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData,
	MemberExprData, ArrayAccessData,
	ConditionalExprData, TypeAssertionData, CallExprData,
	ObjectLiteralData, ArrayLiteralData,
	UpdateExprData, NewExprData, MoveExprData, SpreadExprData,
	ExprStmtData, HiddenStdConvData, HiddenDerefData,
} from "../../ast/node";
import { Type, TypeKind, getProperty, getMinArity } from "../../checker/types";
import { SymbolKind } from "../../checker/symbol";
import {
	CGen, CProc, CLoc, CLocKind, CStorageLoc, Builder, CSection,
	initLoc, noLoc, rdLoc,
	add, addLine, sec,
	pStmts, getTemp, nameSetHas, emitStmtsLine, internString,
} from "./context";
import { mangle, mangleFieldName, safeName } from "./names";
import { getTypeDesc, isNrvoReturnType } from "./types";
import { formatCNumber, cBoolLiteral, cNullLiteral, cStringLiteral, msStringPoolRef } from "./literals";
import { charAt, sliceStr, findChar } from "../../utils/string";
import { check } from "std/testing";

// ===== Iterative genExpr infrastructure =====
// Post-order stack traversal: Discover pushes children, Emit combines results.

interface ExprStackItem {
	node: Node;
	phase: number;       // 0 = Discover, 1 = Emit
	childCount: number;  // results to pop during Emit
	tag: number;         // sub-case dispatch (0 = default)
}

const TAG_DEFAULT = 0;
const TAG_CALL_OVERLOAD = 2;
const TAG_CALL_DIRECT = 3;
const TAG_CALL_CLOSURE = 4;

// Read i-th child from top N results on the stack.
function peekResult(results: string[], childCount: number, idx: number): string {
	return results[results.length - childCount + idx];
}

// Remove top N results from the stack.
function truncResults(results: string[], count: number): void {
	let i = 0;
	while (i < count) {
		results.pop();
		i += 1;
	}
}

// Comma-join top N results from the stack, then remove them.
function joinChildResults(results: string[], count: number): string {
	let s = "";
	let i = 0;
	while (i < count) {
		if (i > 0) s = s + ", ";
		s = s + results[results.length - count + i];
		i += 1;
	}
	truncResults(results, count);
	return s;
}

function joinArgs(g: CGen, p: CProc, args: Node[]): string {
	let result = "";
	for (let i = 0; i < args.length; i += 1) {
		if (i > 0) result = result + ", ";
		result = result + genExpr(g, p, args[i]);
	}
	return result;
}

// ===== genExpr — iterative post-order stack traversal =====

export function genExpr(g: CGen, p: CProc, node: Node): string {
	if (node === null) return "MS_NIL";
	const workStack: ExprStackItem[] = [];
	const results: string[] = [];
	workStack.push({ node, phase: 0, childCount: 0, tag: 0 });
	while (workStack.length > 0) {
		const item = workStack[workStack.length - 1];
		workStack.pop();
		if (item.phase === 0) {
			discoverExpr(g, p, item.node, workStack, results);
		} else {
			emitExpr(g, p, item, results);
		}
	}
	if (results.length === 0) return "MS_NIL";
	return results[results.length - 1];
}

// ===== Discover phase: push leaf results or Emit + children =====

function discoverExpr(g: CGen, p: CProc, node: Node, workStack: ExprStackItem[], results: string[]): void {
	if (node === null) {
		results.push("MS_NIL");
		return;
	}
	const kind = node.kind;

	// Leaf nodes — push result directly, no Emit needed
	if (kind === NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		results.push(formatCNumber(d.value));
		return;
	}
	if (kind === NodeKind.StringLiteral) {
		const d = node.data as StringLiteralData;
		const poolName = internString(g.stringPool, d.value);
		results.push(msStringPoolRef(poolName, d.value.length));
		return;
	}
	if (kind === NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		results.push(cBoolLiteral(d.boolValue));
		return;
	}
	if (kind === NodeKind.NullLiteral) {
		results.push(cNullLiteral());
		return;
	}
	if (kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		results.push(safeName(d.name));
		return;
	}
	if (kind === NodeKind.ArrowFunction) {
		results.push("0 /* unlowered ArrowFunction */");
		return;
	}
	if (kind === NodeKind.FunctionExpr) {
		results.push("0 /* unlowered FunctionExpr */");
		return;
	}

	// MoveExpr — passthrough, just redirect to inner node
	if (kind === NodeKind.MoveExpr) {
		const d = node.data as MoveExprData;
		workStack.push({ node: d.moveArg, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// BinaryExpr — 2 children
	if (kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		workStack.push({ node, phase: 1, childCount: 2, tag: TAG_DEFAULT });
		workStack.push({ node: d.right, phase: 0, childCount: 0, tag: 0 });
		workStack.push({ node: d.left, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// UnaryExpr — 1 child
	if (kind === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.operand, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// UpdateExpr — 1 child
	if (kind === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.updateArg, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// MemberExpr — 0 or 1 child (enum member is leaf)
	if (kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		// Enum member: leaf
		if (d.object.kind === NodeKind.Identifier) {
			const id = d.object.data as IdentifierData;
			if (nameSetHas(g.knownEnumNames, safeName(id.name))) {
				results.push(safeName(id.name) + "_" + d.property);
				return;
			}
		}
		// Normal: 1 child (object)
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.object, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// ArrayAccess — 2 children
	if (kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		workStack.push({ node, phase: 1, childCount: 2, tag: TAG_DEFAULT });
		workStack.push({ node: d.index, phase: 0, childCount: 0, tag: 0 });
		workStack.push({ node: d.array, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// ConditionalExpr — 3 children
	if (kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		workStack.push({ node, phase: 1, childCount: 3, tag: TAG_DEFAULT });
		workStack.push({ node: d.ternaryAlternate, phase: 0, childCount: 0, tag: 0 });
		workStack.push({ node: d.ternaryConsequent, phase: 0, childCount: 0, tag: 0 });
		workStack.push({ node: d.ternaryCondition, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// TypeAssertion — 1 child
	if (kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.asExpr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// SpreadExpr — 1 child
	if (kind === NodeKind.SpreadExpr) {
		const d = node.data as SpreadExprData;
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.spreadArg, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// HiddenDeref — 1 child
	if (kind === NodeKind.HiddenDeref) {
		const d = node.data as ExprStmtData;
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.expr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// HiddenAddr — 1 child
	if (kind === NodeKind.HiddenAddr) {
		const d = node.data as ExprStmtData;
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.expr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// HiddenStdConv / HiddenSubConv — 1 child
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const d = node.data as HiddenStdConvData;
		workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		workStack.push({ node: d.convExpr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// ArrayLiteral — keep recursive (side effects: getTemp, emitStmtsLine)
	if (kind === NodeKind.ArrayLiteral) {
		results.push(genArrayLiteral(g, p, node));
		return;
	}

	// CallExpr — dispatch by call type
	if (kind === NodeKind.CallExpr) {
		discoverCallExpr(g, p, node, workStack, results);
		return;
	}

	// ObjectLiteral — N children (property values)
	if (kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		const n = d.properties.length;
		workStack.push({ node, phase: 1, childCount: n, tag: TAG_DEFAULT });
		// Push children in reverse order
		let i = n - 1;
		while (i >= 0) {
			workStack.push({ node: d.properties[i], phase: 0, childCount: 0, tag: 0 });
			i -= 1;
		}
		return;
	}

	// NewExpr — 1 + N children (callee + args)
	if (kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		const n = 1 + d.newArguments.length;
		workStack.push({ node, phase: 1, childCount: n, tag: TAG_DEFAULT });
		// Push in reverse: args then callee
		let i = d.newArguments.length - 1;
		while (i >= 0) {
			workStack.push({ node: d.newArguments[i], phase: 0, childCount: 0, tag: 0 });
			i -= 1;
		}
		workStack.push({ node: d.newCallee, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// Fallback
	results.push("/* unsupported expression */");
}

// ===== Discover CallExpr — split by call type =====

function discoverCallExpr(g: CGen, p: CProc, node: Node, workStack: ExprStackItem[], results: string[]): void {
	const cd = node.data as CallExprData;
	const sym = node.resolvedSym;

	// @runtime("c_name") — keep recursive (emitRuntimeCall has side effects)
	if (sym !== null && sym.runtimeName !== "") {
		results.push(emitRuntimeCall(g, p, sym.runtimeName, cd.arguments));
		return;
	}

	// Overloaded call — args only, name resolved during Emit
	if (sym !== null && sym.overloads !== null && sym.overloads.length > 0) {
		const n = cd.arguments.length;
		workStack.push({ node, phase: 1, childCount: n, tag: TAG_CALL_OVERLOAD });
		let i = n - 1;
		while (i >= 0) {
			workStack.push({ node: cd.arguments[i], phase: 0, childCount: 0, tag: 0 });
			i -= 1;
		}
		return;
	}

	// Direct call or closure call: callee + args
	const n = 1 + cd.arguments.length;
	const tag = cd.isDirectCall ? TAG_CALL_DIRECT : TAG_CALL_CLOSURE;
	workStack.push({ node, phase: 1, childCount: n, tag });
	// Push in reverse: args then callee
	let i = cd.arguments.length - 1;
	while (i >= 0) {
		workStack.push({ node: cd.arguments[i], phase: 0, childCount: 0, tag: 0 });
		i -= 1;
	}
	workStack.push({ node: cd.callee, phase: 0, childCount: 0, tag: 0 });
}

// ===== Emit phase: combine child results =====

function emitExpr(g: CGen, p: CProc, item: ExprStackItem, results: string[]): void {
	const node = item.node;
	const kind = node.kind;
	const cc = item.childCount;
	const tag = item.tag;

	// BinaryExpr
	if (kind === NodeKind.BinaryExpr) {
		const left = peekResult(results, cc, 0);
		const right = peekResult(results, cc, 1);
		truncResults(results, cc);
		const d = node.data as BinaryExprData;
		const cOp = mapBinaryOp(d.operator);
		results.push("(" + left + " " + cOp + " " + right + ")");
		return;
	}

	// UnaryExpr
	if (kind === NodeKind.UnaryExpr) {
		const operand = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as UnaryExprData;
		results.push("(" + d.unaryOp + operand + ")");
		return;
	}

	// UpdateExpr
	if (kind === NodeKind.UpdateExpr) {
		const operand = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as UpdateExprData;
		if (d.isPrefix) {
			results.push("(" + d.updateOp + operand + ")");
		} else {
			results.push("(" + operand + d.updateOp + ")");
		}
		return;
	}

	// MemberExpr
	if (kind === NodeKind.MemberExpr) {
		const obj = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as MemberExprData;
		// Pre-formatted property (e.g. "p->data" from nativeLower) — emit raw
		if (findChar(d.property, ">") >= 0) {
			results.push(obj + "." + d.property);
			return;
		}
		const field = mangleFieldName(d.property);
		results.push(obj + "." + field);
		return;
	}

	// ArrayAccess — after nativeLower, only untyped/raw accesses reach here
	if (kind === NodeKind.ArrayAccess) {
		const arr = peekResult(results, cc, 0);
		const idx = peekResult(results, cc, 1);
		truncResults(results, cc);
		results.push(arr + "[" + idx + "]");
		return;
	}

	// ConditionalExpr
	if (kind === NodeKind.ConditionalExpr) {
		const cond = peekResult(results, cc, 0);
		const cons = peekResult(results, cc, 1);
		const alt = peekResult(results, cc, 2);
		truncResults(results, cc);
		results.push("(" + cond + " ? " + cons + " : " + alt + ")");
		return;
	}

	// TypeAssertion
	if (kind === NodeKind.TypeAssertion) {
		const expr = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as TypeAssertionData;
		const targetType = (node.nodeType !== null) ? getTypeDesc(g, node.nodeType) : mangle(d.asType);
		results.push("((" + targetType + ")" + expr + ")");
		return;
	}

	// SpreadExpr
	if (kind === NodeKind.SpreadExpr) {
		const inner = peekResult(results, cc, 0);
		truncResults(results, cc);
		results.push("/* spread */ " + inner);
		return;
	}

	// HiddenDeref
	if (kind === NodeKind.HiddenDeref) {
		const inner = peekResult(results, cc, 0);
		truncResults(results, cc);
		results.push("(*" + inner + ")");
		return;
	}

	// HiddenAddr
	if (kind === NodeKind.HiddenAddr) {
		const inner = peekResult(results, cc, 0);
		truncResults(results, cc);
		results.push("&(" + inner + ")");
		return;
	}

	// HiddenStdConv / HiddenSubConv
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const inner = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as HiddenStdConvData;
		const targetC = getTypeDesc(g, d.convType);
		results.push("((" + targetC + ")(" + inner + "))");
		return;
	}

	// CallExpr
	if (kind === NodeKind.CallExpr) {
		emitCallExpr(g, p, item, results);
		return;
	}

	// ObjectLiteral
	if (kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		if ((node.flags & NF_CLOSURE) !== 0) {
			// Closure literal: (msClosure){ .fn = ..., .env = ... }
			const fnExpr = peekResult(results, cc, 0);
			const envExpr = peekResult(results, cc, 1);
			truncResults(results, cc);
			results.push("(msClosure){ .fn = (void*)" + fnExpr + ", .env = (void*)&" + envExpr + " }");
		} else {
			// General struct literal
			let prefix = "";
			if (node.nodeType !== null && isNrvoReturnType(node.nodeType)) {
				prefix = "(" + getTypeDesc(g, node.nodeType) + ")";
			}
			let result = prefix + "{ ";
			let i = 0;
			while (i < d.keys.length) {
				if (i > 0) result = result + ", ";
				result = result + "." + mangleFieldName(d.keys[i]) + " = " + peekResult(results, cc, i);
				i += 1;
			}
			result = result + " }";
			truncResults(results, cc);
			results.push(result);
		}
		return;
	}

	// NewExpr
	if (kind === NodeKind.NewExpr) {
		const callee = peekResult(results, cc, 0);
		let args = "";
		let i = 1;
		while (i < cc) {
			if (i > 1) args = args + ", ";
			args = args + peekResult(results, cc, i);
			i += 1;
		}
		truncResults(results, cc);
		results.push(callee + "_new(" + args + ")");
		return;
	}

	// Fallback
	truncResults(results, cc);
	results.push("/* unsupported expression */");
}

// ===== NRVO Return Type Detection =====
// Returns the NRVO return type if the callee returns a struct, null otherwise.

function calleeNrvoReturnType(callNode: Node): Type {
	// Only apply NRVO when callee is a known Function (not runtime macros)
	const cd = callNode.data as CallExprData;
	// Source 1: callee's function type → return type
	if (cd.callee !== null && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		const ret = cd.callee.nodeType.typeReturn;
		if (ret !== null && isNrvoReturnType(ret)) return ret;
	}
	// Source 2: resolvedSym on CallExpr
	if (callNode.resolvedSym !== null && callNode.resolvedSym.symbolType !== null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind === TypeKind.Function && st.typeReturn !== null && isNrvoReturnType(st.typeReturn)) {
			return st.typeReturn;
		}
	}
	return null as unknown as Type;
}

// ===== Emit CallExpr =====

function emitCallExpr(g: CGen, p: CProc, item: ExprStackItem, results: string[]): void {
	const node = item.node;
	const cd = node.data as CallExprData;
	const cc = item.childCount;
	const tag = item.tag;
	const sym = node.resolvedSym;

	if (tag === TAG_CALL_OVERLOAD) {
		// Overloaded: all cc children are args
		const argsStr = joinChildResults(results, cc);
		const idx = cd.resolvedOverloadIdx;
		if (idx === 0 && sym.runtimeName !== "") {
			results.push(sym.runtimeName + "(" + argsStr + ")");
		} else if (idx > 0 && idx - 1 < sym.overloads.length && sym.overloads[idx - 1].runtimeName !== "") {
			results.push(sym.overloads[idx - 1].runtimeName + "(" + argsStr + ")");
		} else if (idx >= 0) {
			results.push(safeName(sym.name) + "__" + idx + "(" + argsStr + ")");
		} else {
			results.push(safeName(sym.name) + "__0(" + argsStr + ")");
		}
		return;
	}

	// Direct or closure: first child is callee, rest are args
	const callee = peekResult(results, cc, 0);
	// C varargs: msNumberArrayFrom(count, (double)(e1), ...) — va_arg reads 8 bytes for double
	const isNumberArrayFrom = callee === "msNumberArrayFrom";
	let argsStr = "";
	let i = 1;
	while (i < cc) {
		if (i > 1) argsStr = argsStr + ", ";
		const arg = peekResult(results, cc, i);
		if (isNumberArrayFrom && i > 1) {
			argsStr = argsStr + "(double)(" + arg + ")";
		} else {
			argsStr = argsStr + arg;
		}
		i += 1;
	}
	truncResults(results, cc);

	if (tag === TAG_CALL_DIRECT) {
		// NRVO: call returns void, result via out-param
		const nrvoType = calleeNrvoReturnType(node);
		if (nrvoType !== null) {
			const cType = getTypeDesc(g, nrvoType);
			const tmp = getTemp(p, cType);
			let nrvoArgs = "&" + tmp.snippet;
			if (argsStr !== "") nrvoArgs = nrvoArgs + ", " + argsStr;
			emitStmtsLine(p, callee + "(" + nrvoArgs + ");");
			results.push(tmp.snippet);
		} else if (argsStr === "") {
			results.push(callee + "()");
		} else {
			results.push(callee + "(" + argsStr + ")");
		}
	} else {
		// TAG_CALL_CLOSURE
		let envArgs = callee + ".env";
		if (argsStr !== "") envArgs = envArgs + ", " + argsStr;
		results.push("((" + callee + ").fn(" + envArgs + "))");
	}
}
// ===== genExprAssign — evaluate expression and assign to dest =====
// For statement-level: `dest = expr;`

export function genExprAssign(g: CGen, p: CProc, node: Node, destSnippet: string): void {
	const snippet = genExpr(g, p, node);
	addLine(pStmts(p), destSnippet + " = " + snippet + ";");
}

// ===== Binary helpers =====

function mapBinaryOp(op: string): string {
	return match (op) {
		"===" | "==" => "==",
		"!==" | "!=" => "!=",
		"&&" => "&&",
		"||" => "||",
		_ => op,
	};
}

// (genUnaryExpr, genHiddenDeref, genMemberExpr, genArrayAccess, genConditionalExpr, genTypeAssertion
//  absorbed into iterative discoverExpr/emitExpr above)

// ===== Call Expression =====
// Direct call: foo(args)
// Closure call: callee.fn(callee.env, args) — detected via isDirectCall flag from closureCallMarker

// Emit a @runtime call: strip & prefix → &first_arg, add array type suffix.
function emitRuntimeCall(g: CGen, p: CProc, runtimeName: string, args: Node[]): string {
	let cName = runtimeName;
	let needsAddr = false;

	// & prefix → mutating method, first arg needs address-of
	if (cName.length > 0 && charAt(cName, 0) === "&") {
		cName = sliceStr(cName, 1, cName.length);
		needsAddr = true;
	}

	// Array type suffix: ms_array_X → ms_array_X_number/_string/_ref
	if (args.length > 0 && args[0].nodeType !== null) {
		const recvType = args[0].nodeType;
		if (recvType.kind === TypeKind.Array) {
			if (cName.length >= 9 && sliceStr(cName, 0, 9) === "ms_array_") {
				if (recvType.typeReturn !== null) {
					const ek = recvType.typeReturn.kind;
					if (ek === TypeKind.Number || ek === TypeKind.Float64) {
						cName = cName + "_number";
					} else if (ek === TypeKind.String) {
						cName = cName + "_string";
					} else {
						cName = cName + "_ref";
					}
				}
			}
		}
	}

	// Build call with & on first arg if mutating
	if (needsAddr && args.length > 0) {
		let result = cName + "(&(" + genExpr(g, p, args[0]) + ")";
		let i = 1;
		while (i < args.length) {
			result = result + ", " + genExpr(g, p, args[i]);
			i = i + 1;
		}
		return result + ")";
	}
	return cName + "(" + joinArgs(g, p, args) + ")";
}

// ===== Array Literal =====
// Emits runtime array construction based on element type:
//   number[]  → ms_array_number_from(count, (double)e1, ...)
//   string[]  → ms_string_array_new_with(count, e1, ...)
//   other[]   → temp + ms_array_push_ref pattern

function genArrayLiteral(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ArrayLiteralData;

	// Determine array type name from nodeType (for empty array zero-init)
	let arrayTypeName = "msRefArray";
	if (node.nodeType !== null && node.nodeType.kind === TypeKind.Array) {
		const elemType = node.nodeType.typeReturn;
		if (elemType !== null) {
			if (elemType.kind === TypeKind.Number || elemType.kind === TypeKind.Float64) {
				arrayTypeName = "msNumberArray";
			} else if (elemType.kind === TypeKind.String) {
				arrayTypeName = "msStringArray";
			}
		}
	}

	// Empty array: C99 compound literal zero-init
	if (d.elements.length === 0) {
		return "(" + arrayTypeName + "){0}";
	}

	// Non-primitive: temp + push pattern
	// (number/string arrays already lowered to msNumberArrayFrom/msStringArrayFrom CallExpr by nativeLower)
	const tmp = getTemp(p, arrayTypeName);
	const tmpName = tmp.snippet;
	emitStmtsLine(p, tmpName + " = (" + arrayTypeName + "){0};");
	let i = 0;
	while (i < d.elements.length) {
		emitStmtsLine(p, "msRefArrayPush(&" + tmpName + ", " + genExpr(g, p, d.elements[i]) + ");");
		i += 1;
	}
	return tmpName;
}

// ===== Tests =====

import { createCGen, createProc, extract, sec, CSection } from "./context";
import { CheckerContext } from "../../checker/context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { ProgramData, ExprStmtData } from "../../ast/node";

function exprSnippet(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR";
	const prog = pr.value;
	const pd = prog.data as ProgramData;
	if (pd.programStmts.length === 0) return "NO_STMTS";
	const stmt = pd.programStmts[0];
	if (stmt.kind !== NodeKind.ExprStmt) return "NOT_EXPR_STMT";
	const es = stmt.data as ExprStmtData;
	const g = createCGen(null as unknown as CheckerContext, "");
	const p = createProc("test", null as unknown as Type);
	return genExpr(g, p, es.expr);
}

test "integer" { check(exprSnippet("42;") === "42"); }

test "float" { check(exprSnippet("3.14;") === "3.14"); }

test "zero" { check(exprSnippet("0;") === "0"); }

test "simple string uses pool ref" {
	const result = exprSnippet("\"hello\";");
	check(result === "MS_STRING_LIT(&TMP_STR_1, 5)");
}

test "true" { check(exprSnippet("true;") === "MS_TRUE"); }

test "false" { check(exprSnippet("false;") === "MS_FALSE"); }

test "null literal" { check(exprSnippet("null;") === "MS_NIL"); }

test "simple name" { check(exprSnippet("foo;") === "foo"); }

test "addition" { check(exprSnippet("a + b;") === "(a + b)"); }

test "equality" { check(exprSnippet("x === y;") === "(x == y)"); }

test "not equal" { check(exprSnippet("x !== y;") === "(x != y)"); }

test "nested" { check(exprSnippet("a + b * c;") === "(a + (b * c))"); }

test "negation" { check(exprSnippet("-x;") === "(-x)"); }

test "logical not" { check(exprSnippet("!flag;") === "(!flag)"); }

test "no args" { check(exprSnippet("foo();") === "foo()"); }

test "with args" { check(exprSnippet("foo(a, b);") === "foo(a, b)"); }

test "nested call" { check(exprSnippet("foo(bar(x));") === "foo(bar(x))"); }

test "dot access" { check(exprSnippet("obj.x;") === "obj.x"); }

test "bracket access" { check(exprSnippet("arr[0];") === "arr[0]"); }

test "expression index" { check(exprSnippet("arr[i + 1];") === "arr[(i + 1)]"); }

test "conditional" { check(exprSnippet("a ? b : c;") === "(a ? b : c)"); }

test "empty array" {
	// Without nodeType, falls back to generic msRefArray
	check(exprSnippet("[];") === "(msRefArray){0}");
}

test "array with elements no type" {
	// Without nodeType (no checker), falls back to temp + push
	const result = exprSnippet("[1, 2, 3];");
	// Returns temp name (setup emitted to proc stmts)
	check(result.length > 0);
}

test "postfix increment" { check(exprSnippet("x++;") === "(x++)"); }

test "prefix increment" { check(exprSnippet("++x;") === "(++x)"); }

test "postfix decrement" { check(exprSnippet("x--;") === "(x--)"); }

test "prefix decrement" { check(exprSnippet("--x;") === "(--x)"); }

test "simple new" { check(exprSnippet("new Foo();") === "Foo_new()"); }

test "new with args" { check(exprSnippet("new Bar(1, 2);") === "Bar_new(1, 2)"); }

test "move identifier" { check(exprSnippet("move x;") === "x"); }

test "move call" { check(exprSnippet("move f();") === "f()"); }

test "deeply nested binary (100 levels)" {
	// Build: a + a + a + ... (100 times) → deeply nested left-recursive BinaryExpr
	let input = "a";
	let i = 0;
	while (i < 99) {
		input = input + " + a";
		i += 1;
	}
	input = input + ";";
	const result = exprSnippet(input);
	// Should not stack overflow and should produce valid output
	check(result.length > 0);
	// Innermost pair should be (a + a)
	let hasInner = false;
	let j = 0;
	while (j < result.length - 7) {
		if (sliceStr(result, j, j + 7) === "(a + a)") {
			hasInner = true;
		}
		j += 1;
	}
	check(hasInner);
}

test "deeply nested calls (50 levels)" {
	// Build: f(f(f(... f(x) ...)))
	let input = "";
	let i = 0;
	while (i < 50) {
		input = input + "f(";
		i += 1;
	}
	input = input + "x";
	i = 0;
	while (i < 50) {
		input = input + ")";
		i += 1;
	}
	input = input + ";";
	const result = exprSnippet(input);
	check(result.length > 0);
	// Should contain f(f( pattern
	let hasNested = false;
	let j = 0;
	while (j < result.length - 4) {
		if (sliceStr(result, j, j + 4) === "f(f(") {
			hasNested = true;
		}
		j += 1;
	}
	check(hasNested);
}

test "deeply nested ternary (30 levels)" {
	// Build: a ? b : (a ? b : (a ? b : ... c))
	let input = "";
	let i = 0;
	while (i < 30) {
		input = input + "a ? b : ";
		i += 1;
	}
	input = input + "c;";
	const result = exprSnippet(input);
	check(result.length > 0);
}
