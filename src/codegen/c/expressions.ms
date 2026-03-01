// C Codegen — Expression Emission
//
// genExpr returns a C code snippet string for any expression node.
// genExprToLoc fills a CLoc dest (for statement-level assignment).
//
// Follows Nim's ccgexprs.nim dest carrier pattern, adapted for
// MetaScript value-type interfaces (CLoc passed by value → use return).

import {
	Node, NodeKind,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData,
	MemberExprData, ArrayAccessData,
	ConditionalExprData, TypeAssertionData, CallExprData,
	ObjectLiteralData, ArrayLiteralData,
	UpdateExprData, NewExprData, MoveExprData, SpreadExprData,
	ExprStmtData,
} from "../../ast/node";
import { Type, TypeKind, getProperty, getMinArity } from "../../checker/types";
import { Symbol, lookupSymbol, SymbolKind, hasOverloads } from "../../checker/symbol";
import {
	resolveOverloadIdx, scoreCandidatePriority, isNoMatch, emptyCandidateScore, cmpCandidates,
} from "../../checker/compat";
import {
	CGen, CProc, CLoc, CLocKind, CStorageLoc, Builder, CSection,
	initLoc, noLoc, rdLoc,
	add, addLine, sec,
	pStmts, getTemp, nameSetHas, emitStmtsLine, internString,
} from "./context";
import { mangle, mangleFieldName, safeName } from "./names";
import { formatCNumber, cBoolLiteral, cNullLiteral, cStringLiteral, msStringPoolRef } from "./literals";
import { charAt, sliceStr } from "../../utils/string";
import { test, check, testGroup } from "std/testing";

// Join call arguments with comma separator.
function joinArgs(g: CGen, p: CProc, args: Node[]): string {
	let result = "";
	for (let i = 0; i < args.length; i += 1) {
		if (i > 0) result = result + ", ";
		result = result + genExpr(g, p, args[i]);
	}
	return result;
}

// ===== genExpr — returns C snippet for any expression =====

export function genExpr(g: CGen, p: CProc, node: Node): string {
	if (node === null) return "MS_NIL";

	return match (node.kind) {
		NodeKind.NumberLiteral => {
			const d = node.data as NumberLiteralData;
			formatCNumber(d.value);
		},
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			const poolName = internString(g.stringPool, d.value);
			msStringPoolRef(poolName, d.value.length);
		},
		NodeKind.BooleanLiteral => {
			const d = node.data as BooleanLiteralData;
			cBoolLiteral(d.boolValue);
		},
		NodeKind.NullLiteral => {
			cNullLiteral();
		},
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			safeName(d.name);
		},
		NodeKind.BinaryExpr => {
			genBinaryExpr(g, p, node);
		},
		NodeKind.UnaryExpr => {
			genUnaryExpr(g, p, node);
		},
		NodeKind.MemberExpr => {
			genMemberExpr(g, p, node);
		},
		NodeKind.ArrayAccess => {
			genArrayAccess(g, p, node);
		},
		NodeKind.ConditionalExpr => {
			genConditionalExpr(g, p, node);
		},
		NodeKind.TypeAssertion => {
			genTypeAssertion(g, p, node);
		},
		NodeKind.CallExpr => {
			genCallExpr(g, p, node);
		},
		NodeKind.ObjectLiteral => {
			genObjectLiteral(g, p, node);
		},
		NodeKind.ArrayLiteral => {
			genArrayLiteral(g, p, node);
		},
		NodeKind.ArrowFunction => {
			genArrowFunction(g, p, node);
		},
		NodeKind.UpdateExpr => {
			genUpdateExpr(g, p, node);
		},
		NodeKind.NewExpr => {
			genNewExpr(g, p, node);
		},
		NodeKind.MoveExpr => {
			genMoveExpr(g, p, node);
		},
		NodeKind.SpreadExpr => {
			genSpreadExpr(g, p, node);
		},
		NodeKind.FunctionExpr => {
			genFunctionExpr(g, p, node);
		},
		NodeKind.HiddenDeref => {
			genHiddenDeref(g, p, node);
		},
		_ => "/* unsupported expr */0",
	};
}

// ===== genExprAssign — evaluate expression and assign to dest =====
// For statement-level: `dest = expr;`

export function genExprAssign(g: CGen, p: CProc, node: Node, destSnippet: string): void {
	const snippet = genExpr(g, p, node);
	addLine(pStmts(p), destSnippet + " = " + snippet + ";");
}

// ===== Binary Expression =====

function genBinaryExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as BinaryExprData;
	// String index assignment: s[i] = ch → ms_string_set_char(&s, i, ch)
	if (d.operator === "=" && d.left.kind === NodeKind.ArrayAccess) {
		const ad = d.left.data as ArrayAccessData;
		if (isStringTyped(ad.array)) {
			const arr = genExpr(g, p, ad.array);
			const idx = genExpr(g, p, ad.index);
			const val = genExpr(g, p, d.right);
			// COW guard: ensure string payload is mutable before writing
			return "(msStringPrepareMutation(&" + arr + "), msStringSetChar(&" + arr + ", " + idx + ", " + val + "))";
		}
		if (isArrayTyped(ad.array)) {
			const arr = genExpr(g, p, ad.array);
			const idx = genExpr(g, p, ad.index);
			const val = genExpr(g, p, d.right);
			return arr + ".p->data[" + idx + "] = " + val;
		}
	}
	const left = genExpr(g, p, d.left);
	const right = genExpr(g, p, d.right);
	// String comparison: use runtime functions instead of C operators
	if (isStringTyped(d.left) || isStringTyped(d.right)) {
		if (d.operator === "===" || d.operator === "==") {
			if (isEmptyStringLiteral(d.right)) return "(" + left + ".len == 0)";
			if (isEmptyStringLiteral(d.left)) return "(" + right + ".len == 0)";
			return "msStringEquals(" + left + ", " + right + ")";
		}
		if (d.operator === "!==" || d.operator === "!=") {
			if (isEmptyStringLiteral(d.right)) return "(" + left + ".len != 0)";
			if (isEmptyStringLiteral(d.left)) return "(" + right + ".len != 0)";
			return "(!msStringEquals(" + left + ", " + right + "))";
		}
		if (d.operator === "<" || d.operator === ">" || d.operator === "<=" || d.operator === ">=") {
			return "(msStringCompare(" + left + ", " + right + ") " + d.operator + " 0)";
		}
		if (d.operator === "+") {
			// Concat chain fusion: s + t + u → ms_string_concat_many(3, s, t, u)
			// AST is left-associative: ((s + t) + u) — walk left spine, collect rights
			let operands: string[] = [];
			let cur = node;
			while (cur.kind === NodeKind.BinaryExpr) {
				const cd = cur.data as BinaryExprData;
				if (cd.operator !== "+" || !isStringTyped(cd.left)) break;
				operands.push(genExpr(g, p, cd.right));
				cur = cd.left;
			}
			operands.push(genExpr(g, p, cur));
			// operands are in reverse order (rightmost first), reverse them
			let reversed: string[] = [];
			let ri = operands.length - 1;
			while (ri >= 0) {
				reversed.push(operands[ri]);
				ri -= 1;
			}
			if (reversed.length === 2) {
				return "msStringConcat(" + reversed[0] + ", " + reversed[1] + ")";
			}
			let result = "msStringConcatMany(" + reversed.length;
			let i = 0;
			while (i < reversed.length) {
				result = result + ", " + reversed[i];
				i += 1;
			}
			return result + ")";
		}
	}
	const cOp = mapBinaryOp(d.operator);
	return "(" + left + " " + cOp + " " + right + ")";
}

function isStringTyped(node: Node): boolean {
	if (node.nodeType === null) return false;
	return node.nodeType.kind === TypeKind.String;
}

function isArrayTyped(node: Node): boolean {
	if (node.nodeType === null) return false;
	return node.nodeType.kind === TypeKind.Array;
}

function isEmptyStringLiteral(node: Node): boolean {
	if (node.kind !== NodeKind.StringLiteral) return false;
	const d = node.data as StringLiteralData;
	return d.value === "";
}

function mapBinaryOp(op: string): string {
	return match (op) {
		"===" | "==" => "==",
		"!==" | "!=" => "!=",
		"&&" => "&&",
		"||" => "||",
		_ => op,
	};
}

// ===== Unary Expression =====

function genUnaryExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as UnaryExprData;
	const operand = genExpr(g, p, d.operand);
	return "(" + d.unaryOp + operand + ")";
}

// ===== Hidden Deref (compiler-inserted pointer dereference) =====

function genHiddenDeref(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ExprStmtData;
	const inner = genExpr(g, p, d.expr);
	return "(*" + inner + ")";
}

// ===== Member Expression =====

function genMemberExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as MemberExprData;
	const obj = genExpr(g, p, d.object);
	// Builtin property remapping: .length → .len for string and array types
	if (d.property === "length" && d.object.nodeType !== null) {
		if (d.object.nodeType.kind === TypeKind.String || d.object.nodeType.kind === TypeKind.Array) {
			return obj + ".len";
		}
	}
	const field = mangleFieldName(d.property);
	return obj + "." + field;
}

// ===== Array Access =====
// Runtime arrays use .p->data[idx] (struct with payload pointer).
// Raw C arrays keep arr[idx] (fallback when nodeType unavailable).

function genArrayAccess(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ArrayAccessData;
	const arr = genExpr(g, p, d.array);
	const idx = genExpr(g, p, d.index);
	// String index read: s[i] → bounds check + ms_string_char_at(s, i)
	if (isStringTyped(d.array)) {
		return "({ int32_t __idx = " + idx + "; if ((uint64_t)__idx >= (uint64_t)(" + arr + ".len)) msRaiseIndexError(__idx, " + arr + ".len); msStringCharAt(" + arr + ", __idx); })";
	}
	// Array index read: arr[i] → bounds check + arr.p->data[i]
	if (d.array.nodeType !== null && d.array.nodeType.kind === TypeKind.Array) {
		return "({ int32_t __idx = " + idx + "; if ((uint64_t)__idx >= (uint64_t)(" + arr + ".len)) msRaiseIndexError(__idx, " + arr + ".len); " + arr + ".p->data[__idx]; })";
	}
	return arr + "[" + idx + "]";
}

// ===== Conditional Expression =====

function genConditionalExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ConditionalExprData;
	const cond = genExpr(g, p, d.ternaryCondition);
	const cons = genExpr(g, p, d.ternaryConsequent);
	const alt = genExpr(g, p, d.ternaryAlternate);
	return "(" + cond + " ? " + cons + " : " + alt + ")";
}

// ===== Type Assertion (as cast) =====

function genTypeAssertion(g: CGen, p: CProc, node: Node): string {
	const d = node.data as TypeAssertionData;
	const expr = genExpr(g, p, d.asExpr);
	const targetType = mangle(d.asType);
	return "((" + targetType + ")" + expr + ")";
}

// ===== Call Expression =====
// Detects closure calls vs direct calls using fnDeclNames from closureCallMarker.
// Direct call: foo(args)
// Closure call: MS_CLOSURE_CALL(closureVar, args) or closureVar.fn(closureVar.env, args)

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

function genCallExpr(g: CGen, p: CProc, node: Node): string {
	const cd = node.data as CallExprData;
	let isDirect = false;

	// If no fnDeclNames were collected (no closure marker pass), treat all as direct
	if (g.fnDeclNames.names.length === 0) isDirect = true;

	// Check if callee is a known direct function (not a closure)
	if (cd.callee.kind === NodeKind.Identifier) {
		const id = cd.callee.data as IdentifierData;
		if (nameSetHas(g.fnDeclNames, id.name)) isDirect = true;

		// @runtime("c_name") on top-level function — emit C name directly (Nim sfImportc)
		// Handles & prefix (mutating → address-of on first arg) and array type suffix.
		if (g.checkerCtx !== null) {
			const sym = lookupSymbol(g.checkerCtx.table, id.name);
			if (sym !== null && sym.runtimeName !== "") {
				return emitRuntimeCall(g, p, sym.runtimeName, cd.arguments);
			}
			// Overload resolution: resolve call to correct mangled name
			if (sym !== null && hasOverloads(sym)) {
				const mangledName = resolveOverloadCallName(g, p, sym, node);
				return mangledName + "(" + joinArgs(g, p, cd.arguments) + ")";
			}
			// Unknown identifier (no symbol) → direct call.
			// DRC-injected lifecycle functions (msStringDecref, msDecref, etc.)
			// have no symbol in the checker table — emit as direct C function calls.
			if (sym === null) isDirect = true;
		}
	}

	// Class method call: console.log(x) → ms_println(x)
	// Unwrap HiddenDeref: checker inserts HiddenDeref for class member access (pointer types)
	if (cd.callee.kind === NodeKind.MemberExpr && g.checkerCtx !== null) {
		const me = cd.callee.data as MemberExprData;
		let calleeObj = me.object;
		if (calleeObj.kind === NodeKind.HiddenDeref) {
			const hd = calleeObj.data as ExprStmtData;
			calleeObj = hd.expr;
		}
		if (calleeObj.kind === NodeKind.Identifier) {
			const objId = calleeObj.data as IdentifierData;
			const objSym = lookupSymbol(g.checkerCtx.table, objId.name);
			if (objSym !== null && objSym.symbolKind === SymbolKind.Class) {
				const methodType = getProperty(objSym.symbolType, me.property);
				if (methodType.typeName !== "") {
					return methodType.typeName + "(" + joinArgs(g, p, cd.arguments) + ")";
				}
			}
		}
	}

	// MemberExpr callee is always a direct call (method/field access)
	if (cd.callee.kind === NodeKind.MemberExpr) isDirect = true;

	const callee = genExpr(g, p, cd.callee);

	if (isDirect) {
		return callee + "(" + joinArgs(g, p, cd.arguments) + ")";
	}

	// Closure call: callee.fn(callee.env, args...)
	let envArgs = callee + ".env";
	const rest = joinArgs(g, p, cd.arguments);
	if (rest !== "") envArgs = envArgs + ", " + rest;
	return "((" + callee + ").fn(" + envArgs + "))";
}

// ===== Overload Call Resolution =====

function resolveOverloadCallName(g: CGen, p: CProc, sym: Symbol, callNode: Node): string {
	const cd = callNode.data as CallExprData;
	// Build candidate Type[] from sym + overloads
	const candidates: Type[] = [];
	candidates.push(sym.symbolType);
	let oi = 0;
	while (oi < sym.overloads.length) {
		candidates.push(sym.overloads[oi].symbolType);
		oi = oi + 1;
	}
	// Collect arg types from nodeType annotations (set by checker)
	const argTypes: Type[] = [];
	let ai = 0;
	while (ai < cd.arguments.length) {
		if (cd.arguments[ai].nodeType !== null) {
			argTypes.push(cd.arguments[ai].nodeType);
		} else {
			// Fallback: use unknown type
			argTypes.push(sym.symbolType);
		}
		ai = ai + 1;
	}
	// Inheritance-aware overload resolution (matches checker's resolveOverloadIdxWithInheritance)
	const idx = codegenResolveOverloadIdx(g, candidates, argTypes);
	if (idx >= 0) {
		// Check if winner has runtimeName
		if (idx === 0 && sym.runtimeName !== "") {
			return sym.runtimeName;
		}
		if (idx > 0 && sym.overloads[idx - 1].runtimeName !== "") {
			return sym.overloads[idx - 1].runtimeName;
		}
		return safeName(sym.name) + "__" + idx;
	}
	// Fallback: no match → use primary name (checker should have caught the error)
	return safeName(sym.name) + "__0";
}

// Inline inheritance-aware overload resolution for codegen.
// Mirrors resolveOverloadIdxWithInheritance from checkExprPass.ms without importing it.
function codegenResolveOverloadIdx(g: CGen, candidates: Type[], argTypes: Type[]): number {
	let bestIdx = -1;
	let bestScore = emptyCandidateScore();
	let bestType: Type = null as unknown as Type;
	let ambiguous = false;
	let i = 0;
	while (i < candidates.length) {
		if (candidates[i].kind !== TypeKind.Function) { i = i + 1; continue; }
		const score = scoreCandidatePriority(candidates[i].typeChildren, argTypes, getMinArity(candidates[i]));
		if (isNoMatch(score)) { i = i + 1; continue; }
		// Compute inheritance penalty via typeExtra chain
		let maxDepth = -1;
		let pi = 0;
		while (pi < candidates[i].typeChildren.length && pi < argTypes.length) {
			const pType = candidates[i].typeChildren[pi];
			const aType = argTypes[pi];
			if (pType.kind === TypeKind.Object && aType.kind === TypeKind.Object) {
				if (pType.typeName !== "" && aType.typeName !== "" && pType.typeName !== aType.typeName) {
					const depth = codegenInheritanceDepth(g, aType, pType);
					if (depth > 0 && (maxDepth === -1 || depth > maxDepth)) {
						maxDepth = depth;
					}
				}
			}
			pi = pi + 1;
		}
		if (maxDepth > 0) {
			score.inheritancePenalty = maxDepth;
		}
		if (bestIdx === -1) {
			bestIdx = i;
			bestScore = score;
			bestType = candidates[i];
			ambiguous = false;
		} else {
			const cmp = cmpCandidates(score, bestScore, candidates[i], bestType);
			if (cmp > 0) {
				bestIdx = i;
				bestScore = score;
				bestType = candidates[i];
				ambiguous = false;
			} else if (cmp === 0) {
				ambiguous = true;
			}
		}
		i = i + 1;
	}
	if (ambiguous) return -2;
	return bestIdx;
}

// Walk class inheritance chain from sourceType to targetType using checker context.
function codegenInheritanceDepth(g: CGen, sourceType: Type, targetType: Type): number {
	if (sourceType === null || targetType === null) return -1;
	if (sourceType.typeName === "" || targetType.typeName === "") return -1;
	if (g.checkerCtx === null) return -1;
	let current = sourceType;
	let depth = 0;
	while (current !== null) {
		depth = depth + 1;
		if (current.typeExtra === null) return -1;
		if (current.typeExtra.typeName === "") return -1;
		if (current.typeExtra.typeName === targetType.typeName) return depth;
		const baseSym = lookupSymbol(g.checkerCtx.table, current.typeExtra.typeName);
		if (baseSym === null) return -1;
		if (baseSym.symbolKind !== SymbolKind.Class) return -1;
		current = baseSym.symbolType;
		if (depth > 20) return -1;
	}
	return -1;
}

// ===== Object Literal =====
// Two cases:
// 1. Closure pair: { fn: liftedFn, env: { captured vars } } → (msClosure){ .fn = ..., .env = ... }
// 2. General struct: { x: 1, y: 2 } → (StructType){ .x = 1, .y = 2 }

function genObjectLiteral(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ObjectLiteralData;

	// Detect closure pair: keys are ["fn", "env"] with exactly 2 entries
	if (d.keys.length === 2 && d.keys[0] === "fn" && d.keys[1] === "env") {
		// Closure literal: (msClosure){ .fn = ..., .env = ... }
		const fnExpr = genExpr(g, p, d.properties[0]);
		const envExpr = genExpr(g, p, d.properties[1]);
		return "(msClosure){ .fn = (void*)" + fnExpr + ", .env = (void*)&" + envExpr + " }";
	}

	// General struct literal: { .field1 = val1, .field2 = val2 }
	let result = "{ ";
	for (let i = 0; i < d.keys.length; i += 1) {
		if (i > 0) result = result + ", ";
		result = result + "." + mangleFieldName(d.keys[i]) + " = " + genExpr(g, p, d.properties[i]);
	}
	result = result + " }";
	return result;
}

// ===== Array Literal =====
// Emits runtime array construction based on element type:
//   number[]  → ms_array_number_from(count, (double)e1, ...)
//   string[]  → ms_string_array_new_with(count, e1, ...)
//   other[]   → temp + ms_array_push_ref pattern

function genArrayLiteral(g: CGen, p: CProc, node: Node): string {
	const d = node.data as ArrayLiteralData;

	// Determine element type from nodeType (set by checker)
	let elemKind = TypeKind.Void;
	let arrayTypeName = "msArray";
	if (node.nodeType !== null && node.nodeType.kind === TypeKind.Array) {
		if (node.nodeType.typeReturn !== null) {
			elemKind = node.nodeType.typeReturn.kind;
		}
		if (elemKind === TypeKind.Number || elemKind === TypeKind.Float64) {
			arrayTypeName = "msNumberArray";
		} else if (elemKind === TypeKind.String) {
			arrayTypeName = "msStringArray";
		}
	}

	// Empty array: C99 compound literal zero-init
	if (d.elements.length === 0) {
		return "(" + arrayTypeName + "){0}";
	}

	// Number array: variadic ms_array_number_from(count, (double)e1, ...)
	// CRITICAL: cast to (double) — C varargs promotes int literals to 4 bytes
	// but va_arg(args, double) reads 8 bytes → garbage without cast
	if (elemKind === TypeKind.Number || elemKind === TypeKind.Float64) {
		let result = "msNumberArrayFrom(" + d.elements.length;
		let i = 0;
		while (i < d.elements.length) {
			result = result + ", (double)(" + genExpr(g, p, d.elements[i]) + ")";
			i += 1;
		}
		return result + ")";
	}

	// String array: variadic ms_string_array_new_with(count, e1, ...)
	if (elemKind === TypeKind.String) {
		let result = "msStringArrayFrom(" + d.elements.length;
		let i = 0;
		while (i < d.elements.length) {
			result = result + ", " + genExpr(g, p, d.elements[i]);
			i += 1;
		}
		return result + ")";
	}

	// Non-primitive: temp + push pattern
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

// ===== Arrow Function (non-capturing) =====
// Non-capturing arrows that survive lambda lifting are emitted as function pointers.
// Capturing arrows are already transformed into closure pairs (ObjectLiteral).

function genArrowFunction(g: CGen, p: CProc, node: Node): string {
	// Lambda lifting (Phase 3) lifts all ArrowFunctions — this path is dead.
	return "0 /* unlowered ArrowFunction */";
}

// ===== Update Expression (i++, ++i, i--, --i) =====
// Phase 3 lowers statement-position updates to assignment.
// Expression-position updates survive — emit directly (C supports natively).

function genUpdateExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as UpdateExprData;
	const operand = genExpr(g, p, d.updateArg);
	if (d.isPrefix) return "(" + d.updateOp + operand + ")";
	return "(" + operand + d.updateOp + ")";
}

// ===== New Expression =====
// `new Foo(args)` → `ClassName_new(args)` (constructor call).
// Classes emit ClassName_new() in declarations.ms.

function genNewExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as NewExprData;
	const callee = genExpr(g, p, d.newCallee);
	let args = "";
	for (let i = 0; i < d.newArguments.length; i += 1) {
		if (i > 0) args = args + ", ";
		args = args + genExpr(g, p, d.newArguments[i]);
	}
	return callee + "_new(" + args + ")";
}

// ===== Move Expression =====
// `move x` → emit inner expression. DRC (Phase 4) already injected
// ms_was_moved(&x) after the move site. Codegen just passes through.

function genMoveExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as MoveExprData;
	return genExpr(g, p, d.moveArg);
}

// ===== Spread Expression =====
// Phase 3 inlines literal spreads: `f(...[a, b])` → `f(a, b)`.
// Dynamic spreads (`f(...arr)`) survive — no C equivalent.
// Emit the inner expression with a warning comment.

function genSpreadExpr(g: CGen, p: CProc, node: Node): string {
	const d = node.data as SpreadExprData;
	return "/* spread */ " + genExpr(g, p, d.spreadArg);
}

// ===== Function Expression =====
// Non-capturing function expressions are lifted to module-level functions.
// Capturing ones are already transformed to closure pairs by lambda lifting.
// Same pattern as ArrowFunction.

function genFunctionExpr(g: CGen, p: CProc, node: Node): string {
	// Lambda lifting (Phase 3) lifts all FunctionExpr — this path is dead.
	return "0 /* unlowered FunctionExpr */";
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
	const g = createCGen(null as unknown as CheckerContext);
	const p = createProc("test", null as unknown as Type);
	return genExpr(g, p, es.expr);
}

testGroup("C Expr Number", () => {
	test("integer", () => {
		check(exprSnippet("42;") === "42");
	});
	test("float", () => {
		check(exprSnippet("3.14;") === "3.14");
	});
	test("zero", () => {
		check(exprSnippet("0;") === "0");
	});
});

testGroup("C Expr String", () => {
	test("simple string uses pool ref", () => {
		const result = exprSnippet("\"hello\";");
		check(result === "MS_STRING_LIT(&TMP_STR_1, 5)");
	});
});

testGroup("C Expr Bool", () => {
	test("true", () => {
		check(exprSnippet("true;") === "MS_TRUE");
	});
	test("false", () => {
		check(exprSnippet("false;") === "MS_FALSE");
	});
});

testGroup("C Expr Null", () => {
	test("null literal", () => {
		check(exprSnippet("null;") === "MS_NIL");
	});
});

testGroup("C Expr Identifier", () => {
	test("simple name", () => {
		check(exprSnippet("foo;") === "foo");
	});
});

testGroup("C Expr Binary", () => {
	test("addition", () => {
		check(exprSnippet("a + b;") === "(a + b)");
	});
	test("equality", () => {
		check(exprSnippet("x === y;") === "(x == y)");
	});
	test("not equal", () => {
		check(exprSnippet("x !== y;") === "(x != y)");
	});
	test("nested", () => {
		check(exprSnippet("a + b * c;") === "(a + (b * c))");
	});
});

testGroup("C Expr Unary", () => {
	test("negation", () => {
		check(exprSnippet("-x;") === "(-x)");
	});
	test("logical not", () => {
		check(exprSnippet("!flag;") === "(!flag)");
	});
});

testGroup("C Expr Call", () => {
	test("no args", () => {
		check(exprSnippet("foo();") === "foo()");
	});
	test("with args", () => {
		check(exprSnippet("foo(a, b);") === "foo(a, b)");
	});
	test("nested call", () => {
		check(exprSnippet("foo(bar(x));") === "foo(bar(x))");
	});
});

testGroup("C Expr Member", () => {
	test("dot access", () => {
		check(exprSnippet("obj.x;") === "obj.x");
	});
});

testGroup("C Expr Array Access", () => {
	test("bracket access", () => {
		check(exprSnippet("arr[0];") === "arr[0]");
	});
	test("expression index", () => {
		check(exprSnippet("arr[i + 1];") === "arr[(i + 1)]");
	});
});

testGroup("C Expr Ternary", () => {
	test("conditional", () => {
		check(exprSnippet("a ? b : c;") === "(a ? b : c)");
	});
});


testGroup("C Expr Array", () => {
	test("empty array", () => {
		// Without nodeType, falls back to generic msArray
		check(exprSnippet("[];") === "(msArray){0}");
	});
	test("array with elements no type", () => {
		// Without nodeType (no checker), falls back to temp + push
		const result = exprSnippet("[1, 2, 3];");
		// Returns temp name (setup emitted to proc stmts)
		check(result.length > 0);
	});
});

testGroup("C Expr Update", () => {
	test("postfix increment", () => {
		check(exprSnippet("x++;") === "(x++)");
	});
	test("prefix increment", () => {
		check(exprSnippet("++x;") === "(++x)");
	});
	test("postfix decrement", () => {
		check(exprSnippet("x--;") === "(x--)");
	});
	test("prefix decrement", () => {
		check(exprSnippet("--x;") === "(--x)");
	});
});

testGroup("C Expr New", () => {
	test("simple new", () => {
		check(exprSnippet("new Foo();") === "Foo_new()");
	});
	test("new with args", () => {
		check(exprSnippet("new Bar(1, 2);") === "Bar_new(1, 2)");
	});
});

testGroup("C Expr Move", () => {
	test("move identifier", () => {
		check(exprSnippet("move x;") === "x");
	});
	test("move call", () => {
		check(exprSnippet("move f();") === "f()");
	});
});
