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
	emitProcLocalsLine,
} from "./context";
import { mangle, mangleFieldName, safeName } from "./names";
import { getTypeDesc, isNrvoReturnType, getCalleeReturnType, intToString, isPointerType, annotationToC, genClHalfCast, genClFullCast } from "./types";
import { formatCNumber, cBoolLiteral, cNullLiteral, cStringLiteral, msStringPoolRef } from "./literals";
import { charAt, sliceStr, findChar, startsWith } from "../../utils/string";

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
// TAG_CALL_CLOSURE removed — closure calls lowered to direct calls in closureCallLower.ms

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
		// Built-in numeric constants → C99 macros
		if (d.name === "NaN") { results.push("NAN"); return; }
		if (d.name === "Infinity") { results.push("INFINITY"); return; }
		// Auto-declare DRC sink temps on first use (zero-init for goto safety)
		if (startsWith(d.name, "$sink_") && p !== null) {
			let alreadySeen = false;
			for (const s of p.seenSinks) { if (s === d.name) alreadySeen = true; }
			if (!alreadySeen) {
				p.seenSinks.push(d.name);
				const cType = node.nodeType !== null ? getTypeDesc(g, node.nodeType) : "void*";
				emitProcLocalsLine(p, "  " + cType + " " + safeName(d.name) + " = {0};");
			}
		}
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

	// MemberExpr — 1 child (object)
	// Note: Enum member access (Color.Red) is rewritten to Identifier("Color_Red")
	// by the checker (checkMemberExpr), so MemberExpr with enum objects never reaches codegen.
	if (kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
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
		// Propagate field types from parent struct to untyped children (e.g. empty array literals)
		if (node.nodeType !== null && node.nodeType.typeChildren !== null) {
			let fi = 0;
			while (fi < n && fi < d.keys.length) {
				if (d.properties[fi].nodeType === null) {
					const fieldType = getProperty(node.nodeType, d.keys[fi]);
					if (fieldType !== null) {
						d.properties[fi].nodeType = fieldType;
					}
				}
				fi += 1;
			}
		}
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

	// extern from "c_name" — keep recursive (emitNativeCall has side effects)
	if (sym !== null && sym.nativeName !== "") {
		results.push(emitNativeCall(g, p, sym.nativeName, cd.arguments));
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

	// Direct call: callee + args
	const n = 1 + cd.arguments.length;
	const tag = TAG_CALL_DIRECT;
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
		let finalRight = right;
		if (d.operator === "=" && d.left.nodeType !== null && d.right.nodeType !== null) {
			const leftCType = getTypeDesc(g, d.left.nodeType);
			const rightCType = getTypeDesc(g, d.right.nodeType);
			if (leftCType !== rightCType && leftCType !== "void*" && rightCType !== "void") {
				const destIsPtr = leftCType.indexOf("*") >= 0;
				const srcIsPtr = rightCType.indexOf("*") >= 0;
				if (destIsPtr === srcIsPtr) {
					finalRight = "((" + leftCType + ")(" + right + "))";
				}
			}
		}
		// Modulo on doubles requires fmod() in C (% is integer-only)
		// Integer types (int32, int64 etc.) keep native %
		if (d.operator === "%") {
			const lt = d.left.nodeType;
			const isInt = lt !== null && (lt.kind === TypeKind.Int32 || lt.kind === TypeKind.Int64 || lt.kind === TypeKind.Uint32);
			if (!isInt) {
				results.push("fmod(" + left + ", " + finalRight + ")");
				return;
			}
		}
		const cOp = mapBinaryOp(d.operator);
		results.push("(" + left + " " + cOp + " " + finalRight + ")");
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
		// Universal .length/.byteLength → .len fallback
		// No C struct in our system has .length — all arrays/strings/maps use .len
		// nativeLower remaps when objType is available; this catches null-objType cases
		if (d.property === "length" || d.property === "byteLength") {
			results.push(obj + ".len");
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
		// Nim's clHalf pattern: "__clHalf__" marker → generate typed fn pointer cast
		// from nodeType (the callee's Function type). Codegen-only concern.
		// See ccgtypes.nim:getClosureType(m, typ, clHalf)
		let targetType = "";
		if (d.asType === "__clFull__") {
			targetType = genClFullCast(g, node.nodeType);
		} else if (d.asType === "__clHalf__") {
			targetType = genClHalfCast(g, node.nodeType);
		} else if (node.nodeType !== null) {
			targetType = getTypeDesc(g, node.nodeType);
		} else {
			targetType = mangle(d.asType);
		}
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
			// Nim pattern: env is heap-allocated via msAllocTyped, fields initialized,
			// then closure pair references the pointer.
			const fnExpr = peekResult(results, cc, 0);
			const envExpr = peekResult(results, cc, 1);
			truncResults(results, cc);
			if (envExpr === "MS_NIL" || envExpr === "NULL") {
				results.push("(msClosure){ .fn = (void*)" + fnExpr + ", .env = NULL }");
			} else {
				// Nim pattern: heap-allocate env struct, init fields, use pointer.
				const envNode = d.properties[1];
				const envTypeName = (envNode !== null && envNode.nodeType !== null) ? getTypeDesc(g, envNode.nodeType) : "void";
				g.labels += 1;
				const envTemp = "_env" + g.labels + "_";
				emitProcLocalsLine(p, envTypeName + "* " + envTemp + ";");
				emitStmtsLine(p, envTemp + " = (" + envTypeName + "*)msAllocTyped(sizeof(" + envTypeName + "), NULL);");
				emitStmtsLine(p, "*" + envTemp + " = " + envExpr + ";");
				results.push("(msClosure){ .fn = (void*)" + fnExpr + ", .env = (void*)" + envTemp + " }");
			}
		} else {
			// General struct literal — ALL compound literals need (Type) prefix in C
			let prefix = "";
			if (node.nodeType !== null) {
				const td = getTypeDesc(g, node.nodeType);
				if (td !== "void*" && td !== "double") {
					prefix = "(" + td + ")";
				}
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

// ===== Emit CallExpr =====

function emitCallExpr(g: CGen, p: CProc, item: ExprStackItem, results: string[]): void {
	const node = item.node;
	const cd = node.data as CallExprData;
	const cc = item.childCount;
	const tag = item.tag;
	const sym = node.resolvedSym;

	if (tag === TAG_CALL_OVERLOAD) {
		// Overloaded: all cc children are args (no callee child)
		const idx = cd.resolvedOverloadIdx;
		// Resolve the chosen overload's function type for ABI shim
		let ovType = sym.symbolType;
		if (idx > 0 && idx - 1 < sym.overloads.length) {
			ovType = sym.overloads[idx - 1].symbolType;
		}
		const hasOvParams = ovType !== null && ovType.kind === TypeKind.Function && ovType.typeChildren !== null;
		// Resolve nativeName early — need to know if & prefix requires first-arg address-of
		let ovNativeName = "";
		if (idx === 0 && sym.nativeName !== "") {
			ovNativeName = sym.nativeName;
		} else if (idx > 0 && idx - 1 < sym.overloads.length && sym.overloads[idx - 1].nativeName !== "") {
			ovNativeName = sym.overloads[idx - 1].nativeName;
		}
		const ovNeedsAddr = hasAddrPrefix(ovNativeName);
		// Build args with pointer/value ABI shim
		let argsStr = "";
		let ai = 0;
		while (ai < cc) {
			if (ai > 0) argsStr = argsStr + ", ";
			let arg = results[results.length - cc + ai];
			// & prefix on nativeName: wrap first arg with &(...)
			if (ovNeedsAddr && ai === 0) {
				arg = "&(" + arg + ")";
			} else if (hasOvParams && ai < ovType.typeChildren.length && ai < cd.arguments.length) {
				const paramType = ovType.typeChildren[ai];
				const argNode = cd.arguments[ai];
				if (paramType !== null && argNode.nodeType !== null && argNode.kind !== NodeKind.HiddenAddr) {
					const paramIsPtr = isPointerType(paramType);
					const argIsPtr = isPointerType(argNode.nodeType);
					if (paramIsPtr && !argIsPtr) {
						arg = "&(" + arg + ")";
					} else if (!paramIsPtr && argIsPtr) {
						arg = "*(" + arg + ")";
					}
				}
			}
			argsStr = argsStr + arg;
			ai += 1;
		}
		truncResults(results, cc);
		if (ovNativeName !== "") {
			results.push(stripAddrPrefix(ovNativeName) + "(" + argsStr + ")");
			return;
		}
		if (idx >= 0) {
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
	// Resolve callee's function type for parameter type checking
	const calleeType = sym !== null && sym.symbolType !== null ? sym.symbolType : (cd.callee.nodeType !== null ? cd.callee.nodeType : null as unknown as Type);
	const hasParamTypes = calleeType !== null && calleeType.kind === TypeKind.Function && calleeType.typeChildren !== null;
	let argsStr = "";
	let i = 1;
	while (i < cc) {
		if (i > 1) argsStr = argsStr + ", ";
		let arg = peekResult(results, cc, i);
		if (isNumberArrayFrom && i > 1) {
			arg = "(double)(" + arg + ")";
		} else if (hasParamTypes) {
			const argIdx = i - 1;
			if (argIdx < calleeType.typeChildren.length && argIdx < cd.arguments.length) {
				const paramType = calleeType.typeChildren[argIdx];
				const argNode = cd.arguments[argIdx];
				if (paramType !== null && argNode.nodeType !== null && argNode.kind !== NodeKind.HiddenAddr) {
					const paramIsPtr = isPointerType(paramType);
					const argIsPtr = isPointerType(argNode.nodeType);
					if (paramIsPtr && !argIsPtr) {
						arg = "&(" + arg + ")";
					} else if (!paramIsPtr && argIsPtr) {
						arg = "*(" + arg + ")";
					}
				}
			}
		}
		argsStr = argsStr + arg;
		i += 1;
	}
	truncResults(results, cc);

	if (tag === TAG_CALL_DIRECT) {
		// TypeAssertion callee already emits ((Type)expr) — outer parens handle precedence.
		const calleeStr = callee;
		// NRVO: call returns void, result via out-param
		const nrvoRet = getCalleeReturnType(node);
		const nrvoType = (nrvoRet !== null && isNrvoReturnType(nrvoRet)) ? nrvoRet : null as unknown as Type;
		if (nrvoType !== null) {
			const cType = getTypeDesc(g, nrvoType);
			const tmp = getTemp(p, cType);
			let nrvoArgs = "&" + tmp.snippet;
			if (argsStr !== "") nrvoArgs = nrvoArgs + ", " + argsStr;
			emitStmtsLine(p, calleeStr + "(" + nrvoArgs + ");");
			results.push(tmp.snippet);
		} else if (argsStr === "") {
			results.push(calleeStr + "()");
		} else {
			results.push(calleeStr + "(" + argsStr + ")");
		}
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

// Emit an extern native call: strip & prefix → &first_arg, add array type suffix.
// Strip & prefix from nativeName. Returns [cleanName, needsAddr].
function stripAddrPrefix(nativeName: string): string {
	if (nativeName.length > 0 && charAt(nativeName, 0) === "&") {
		return sliceStr(nativeName, 1, nativeName.length);
	}
	return nativeName;
}

function hasAddrPrefix(nativeName: string): boolean {
	return nativeName.length > 0 && charAt(nativeName, 0) === "&";
}

function emitNativeCall(g: CGen, p: CProc, nativeName: string, args: Node[]): string {
	const needsAddr = hasAddrPrefix(nativeName);
	let cName = stripAddrPrefix(nativeName);

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

	// Tuple literal: C99 compound literal with designated initializers
	if (node.nodeType !== null && node.nodeType.kind === TypeKind.Tuple) {
		const typeName = getTypeDesc(g, node.nodeType);
		let result = "(" + typeName + "){ ";
		let i = 0;
		while (i < d.elements.length) {
			if (i > 0) result = result + ", ";
			result = result + "._" + intToString(i) + " = " + genExpr(g, p, d.elements[i]);
			i += 1;
		}
		result = result + " }";
		return result;
	}

	// Determine array type name from nodeType — delegates to genArrayType for accurate dispatch
	let arrayTypeName = "msRefArray";
	if (node.nodeType !== null) {
		if (node.nodeType.kind === TypeKind.Array || node.nodeType.kind === TypeKind.SizedArray) {
			arrayTypeName = getTypeDesc(g, node.nodeType);
		} else if (node.nodeType.typeName !== null && node.nodeType.typeName !== "") {
			// Fallback: use string annotation (e.g. "string[]" → "msStringArray")
			arrayTypeName = annotationToC(node.nodeType.typeName);
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
		emitStmtsLine(p, "msGenericArrayPush(&" + tmpName + ", " + genExpr(g, p, d.elements[i]) + ");");
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

test "integer" { expect(exprSnippet("42;") === "42"); }

test "float" { expect(exprSnippet("3.14;") === "3.14"); }

test "zero" { expect(exprSnippet("0;") === "0"); }

test "simple string uses pool ref" {
	const result = exprSnippet("\"hello\";");
	expect(result === "MS_STRING_LIT(&TMP_STR_1, 5)");
}

test "true" { expect(exprSnippet("true;") === "MS_TRUE"); }

test "false" { expect(exprSnippet("false;") === "MS_FALSE"); }

test "null literal" { expect(exprSnippet("null;") === "MS_NIL"); }

test "simple name" { expect(exprSnippet("foo;") === "foo"); }

test "addition" { expect(exprSnippet("a + b;") === "(a + b)"); }

test "equality" { expect(exprSnippet("x === y;") === "(x == y)"); }

test "not equal" { expect(exprSnippet("x !== y;") === "(x != y)"); }

test "nested" { expect(exprSnippet("a + b * c;") === "(a + (b * c))"); }

test "negation" { expect(exprSnippet("-x;") === "(-x)"); }

test "logical not" { expect(exprSnippet("!flag;") === "(!flag)"); }

test "no args" { expect(exprSnippet("foo();") === "foo()"); }

test "with args" { expect(exprSnippet("foo(a, b);") === "foo(a, b)"); }

test "nested call" { expect(exprSnippet("foo(bar(x));") === "foo(bar(x))"); }

test "dot access" { expect(exprSnippet("obj.x;") === "obj.x"); }

test "bracket access" { expect(exprSnippet("arr[0];") === "arr[0]"); }

test "expression index" { expect(exprSnippet("arr[i + 1];") === "arr[(i + 1)]"); }

test "conditional" { expect(exprSnippet("a ? b : c;") === "(a ? b : c)"); }

test "empty array" {
	// Without nodeType, falls back to generic msRefArray
	expect(exprSnippet("[];") === "(msRefArray){0}");
}

test "array with elements no type" {
	// Without nodeType (no checker), falls back to temp + push
	const result = exprSnippet("[1, 2, 3];");
	// Returns temp name (setup emitted to proc stmts)
	expect(result.length > 0);
}

test "postfix increment" { expect(exprSnippet("x++;") === "(x++)"); }

test "prefix increment" { expect(exprSnippet("++x;") === "(++x)"); }

test "postfix decrement" { expect(exprSnippet("x--;") === "(x--)"); }

test "prefix decrement" { expect(exprSnippet("--x;") === "(--x)"); }

test "simple new" { expect(exprSnippet("new Foo();") === "Foo_new()"); }

test "new with args" { expect(exprSnippet("new Bar(1, 2);") === "Bar_new(1, 2)"); }

test "move identifier" { expect(exprSnippet("move x;") === "x"); }

test "move call" { expect(exprSnippet("move f();") === "f()"); }

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
	expect(result.length > 0);
	// Innermost pair should be (a + a)
	let hasInner = false;
	let j = 0;
	while (j < result.length - 7) {
		if (sliceStr(result, j, j + 7) === "(a + a)") {
			hasInner = true;
		}
		j += 1;
	}
	expect(hasInner);
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
	expect(result.length > 0);
	// Should contain f(f( pattern
	let hasNested = false;
	let j = 0;
	while (j < result.length - 4) {
		if (sliceStr(result, j, j + 4) === "f(f(") {
			hasNested = true;
		}
		j += 1;
	}
	expect(hasNested);
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
	expect(result.length > 0);
}
