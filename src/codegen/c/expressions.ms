// C Codegen — Expression Emission
//
// genExpr returns a C code snippet string for any expression node.
// genExprToLoc fills a CLoc dest (for statement-level assignment).
//
// Follows standard reference implementation pattern for destination carriers.
// MetaScript value-type interfaces (CLoc passed by value → use return).

import {
	Node, NodeKind, NodeFlag,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData,
	MemberExprData, ArrayAccessData,
	ConditionalExprData, TypeAssertionData, CallExprData,
	ObjectLiteralData, ArrayLiteralData,
	UpdateExprData, NewExprData, MoveExprData, SpreadExprData,
	ExprStmtData, HiddenStdConvData, HiddenDerefData,
} from "../../ast/node";
import { Type, TypeKind, isIntegerType, getProperty, getMinArity, isInterfaceType, findUnionVariant } from "../../checker/types";
import { Symbol, SymbolKind, SymbolFlag, hasFlag } from "../../checker/symbol";
import {
	CGen, CProc, CLoc, CLocKind, CStorageLoc, Builder, CSection,
	initLoc, noLoc, rdLoc, addrLoc,
	add, addLine, sec,
	pStmts, getTemp, nameSetHas, nameSetAdd, emitStmtsLine, internString,
	emitProcLocalsLine,
} from "./context";
import { mangle, mangleFieldName, mangledFunctionName, safeName } from "./names";
import { getTypeDesc, isNrvoReturnType, getCalleeReturnType, intToString, isPointerType, isNilableValueType, annotationToC, genClHalfCast, genClFullCast, genClHalfCastNrvo, genClFullCastNrvo, ccgIntroducedPtr, ensureTypeInfo, ensureForwardDecl } from "./types";
import { formatCNumber, cBoolLiteral, cNullLiteral, cStringLiteral, msStringPoolRef } from "./literals";
import { charAt, sliceStr, findChar } from "../../utils/string";
import { ensureDrcProto, ensureCrossModuleProto } from "./declarations";

// ===== Reference: argument passing for introduced pointers =====
// Wraps arg for pointer introduction params at call sites.
// Reference: initLocExpr → addAddrLoc patterns.
//
// addrLoc: if NOT indirect → &(snippet); if indirect → snippet (already a pointer)
//
// Our Identifier handler already applies rdLoc (pushes (*name) for indirect params).
// So for indirect args: snippet on stack = (*name), but we need raw pointer = name.
// We use the raw safeName directly (the reference implementation's snippet is always the raw name).
// Check if a node is a CallExpr("msRefArrayAccess", ...) — used by MemberExpr and HiddenDeref
// to handle void* results from ref array macros. Returns true if the node matches.
function isRefArrayAccessCall(node: Node): boolean {
	if (node.kind !== NodeKind.CallExpr) return false;
	const callee = (node.data as CallExprData).callee;
	return callee.kind === NodeKind.Identifier && (callee.data as IdentifierData).name === "msRefArrayAccess";
}

function genArgCcgPtr(g: CGen, arg: string, argNode: Node, p: CProc): string {
	if (argNode.kind === NodeKind.Identifier && isIndirectParam(p, (argNode.data as IdentifierData).name)) {
		// Indirect param: already a pointer — pass raw (reference patterns return snippet as-is)
		return safeName((argNode.data as IdentifierData).name);
	}
	// Not indirect: take address — use safeAddrOf to handle bare compound literals
	return safeAddrOf(g, p, arg, argNode, null);
}

// Reference parity: standard address generation always operates on a named variable,
// never on a bare compound literal. When we need &(expr) and expr is a bare
// compound literal (starts with '{'), hoist it to a temp variable first.
// Reference-aligned address-of: always operates on named locations.
// paramType: optional parameter type from call site for resolving untyped literals.
function safeAddrOf(g: CGen, p: CProc, snippet: string, exprNode: Node, paramType: Type): string {
	if (snippet.length > 0 && snippet.charCodeAt(0) === "{".code) {
		// Bare compound literal — must hoist to temp (Reference: generate temporary + field assignment)
		let cType = "";
		// Try 1: exprNode.nodeType
		if (exprNode !== null && exprNode.nodeType !== null) {
			if (exprNode.nodeType.kind === TypeKind.Union) {
				const od = exprNode.data as ObjectLiteralData;
				if (od.keys !== null && od.keys.length > 0) {
					const unionName = getTypeDesc(g, exprNode.nodeType);
					const keyArr: string[] = [od.keys[0]];
					const varIdx = findUnionVariant(exprNode.nodeType, keyArr, []);
					if (varIdx >= 0) {
						cType = unionName + "_v" + intToString(varIdx);
					}
				}
			} else {
				cType = getTypeDesc(g, exprNode.nodeType);
			}
		}
		// Try 2: paramType (pointer type → strip * to get pointee)
		if ((cType === "" || cType === "void" || cType === "void*") && paramType !== null) {
			// Unwrap pointer to get inner type
			let innerType = paramType;
			if (paramType.kind === TypeKind.Ptr || paramType.kind === TypeKind.Ref) {
				innerType = paramType.typeReturn;
			}
			if (innerType !== null && innerType.kind === TypeKind.Union && exprNode !== null && exprNode.kind === NodeKind.ObjectLiteral) {
				// Union variant: determine variant type from ObjectLiteral keys
				const od = exprNode.data as ObjectLiteralData;
				if (od.keys !== null && od.keys.length > 0) {
					const unionName = getTypeDesc(g, innerType);
					const keyArr: string[] = [od.keys[0]];
					const varIdx = findUnionVariant(innerType, keyArr, []);
					if (varIdx >= 0) {
						// Emit as full union with tag + variant
						p.labels += 1;
						const tmpName = "_clit" + p.labels + "_";
						emitProcLocalsLine(p, unionName + " " + tmpName + ";");
						emitStmtsLine(p, tmpName + "._tag = " + intToString(varIdx) + ";");
						const varTypeName = unionName + "_v" + intToString(varIdx);
						emitStmtsLine(p, tmpName + ".v" + intToString(varIdx) + " = (" + varTypeName + ")" + snippet + ";");
						return "&" + tmpName;
					}
				}
			} else if (innerType !== null) {
				const ptDesc = getTypeDesc(g, innerType);
				if (ptDesc !== "void" && ptDesc !== "void*") {
					cType = ptDesc;
				}
			}
		}
		if (cType !== "" && cType !== "void" && cType !== "void*" && cType !== " ") {
			p.labels += 1;
			const tmpName = "_clit" + p.labels + "_";
			emitProcLocalsLine(p, cType + " " + tmpName + ";");
			emitStmtsLine(p, tmpName + " = (" + cType + ")" + snippet + ";");
			return "&" + tmpName;
		}
	}
	return "&(" + snippet + ")";
}

// ===== Union Variant Index Matching =====
// Matches an `as` target type against a Union's typeChildren by comparing field names.
// Returns the variant index (0-based), or -1 if no match.

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
const TAG_CALL_CLOSURE = 4;  // Reference parity: closure calls — separate path, no forward declarations

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
		// Reference parity: value types can't be nil — emit zero-init instead of NULL.
		if (node.nodeType !== null && isNilableValueType(node.nodeType)) {
			const cType = getTypeDesc(g, node.nodeType);
			results.push("(" + cType + "){0}");
			return;
		}
		results.push(cNullLiteral());
		return;
	}
	if (kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		// Built-in numeric constants → C99 macros
		if (d.name === "NaN") { results.push("NAN"); return; }
		if (d.name === "Infinity") { results.push("INFINITY"); return; }
		// MetaScript has no undefined — emit as NULL or {0} for value types
		if (d.name === "undefined") {
			if (node.nodeType !== null && isNilableValueType(node.nodeType)) {
				const cType = getTypeDesc(g, node.nodeType);
				results.push("(" + cType + "){0}");
				return;
			}
			results.push(cNullLiteral());
			return;
		}
		// Auto-declare DRC sink temps on first use (zero-init for goto safety)
		if (d.name.startsWith("$sink_") && p !== null) {
			let alreadySeen = false;
			for (const s of p.seenSinks) { if (s === d.name) alreadySeen = true; }
			if (!alreadySeen) {
				p.seenSinks.push(d.name);
				const cType = node.nodeType !== null ? getTypeDesc(g, node.nodeType) : "void*";
				emitProcLocalsLine(p, "  " + cType + " " + safeName(d.name) + " = {0};");
			}
		}
		// Ensure cross-module enum constants are emitted (Reference parity: enum definitions per module)
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.Enum) {
			getTypeDesc(g, node.nodeType);
		}
		// Cross-module global variable: emit extern declaration (Reference: standard reference global variable emission)
		// Standard reference implementation checks symbol ownership — we check modulePath (set on imported symbols)
		const idSym = node.resolvedSym;
		if (idSym !== null && idSym.symbolKind === SymbolKind.Variable
			&& idSym.modulePath !== null && idSym.modulePath !== ""
			&& idSym.modulePath !== g.modulePath
			&& !nameSetHas(g.declaredGlobals, d.name)
			&& node.nodeType !== null) {
			const cType = getTypeDesc(g, node.nodeType);
			const sName = safeName(d.name);
			addLine(sec(g, CSection.GlobalVars), "extern " + cType + " " + sName + ";");
			nameSetAdd(g.declaredGlobals, d.name);
		}
		// Module-qualified name for function references (Standard reference parity)
		if (idSym !== null && idSym.symbolKind === SymbolKind.Function) {
			results.push(mangledFunctionName(idSym, d.name, 0));
		} else {
			// Reference parity: build CLoc for identifier, auto-dereference if indirect location
			const loc: CLoc = {
				kind: CLocKind.LocalVar,
				storage: isIndirectParam(p, d.name) ? CStorageLoc.Unknown : CStorageLoc.Stack,
				snippet: safeName(d.name),
				isIndirect: isIndirectParam(p, d.name),
				locType: node.nodeType,
			};
			results.push(rdLoc(loc));
		}
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

	// NewExpr — inline allocation (Standard reference parity: inline object construction)
	if (kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		const calleeName = genExpr(g, p, d.newCallee);
		// Ensure cross-module typeInfo is declared
		ensureTypeInfo(g, calleeName);
		ensureForwardDecl(g, calleeName);
		if (d.newArguments.length === 0) {
			// No-arg new: allocate with zero-init
			results.push("(" + calleeName + "*)msAllocTyped(sizeof(" + calleeName + "), &" + calleeName + "_typeInfo)");
		} else {
			// Positional args → field-by-field assignment using type info
			g.labels += 1;
			const tmp = "_new" + g.labels + "_";
			emitProcLocalsLine(p, calleeName + "* " + tmp + ";");
			emitStmtsLine(p, tmp + " = (" + calleeName + "*)msAllocTyped(sizeof(" + calleeName + "), &" + calleeName + "_typeInfo);");
			// Get field names from the class type (Ref → unwrap to Struct → typeNames)
			const classType = node.nodeType;
			const innerType = (classType !== null && (classType.kind === TypeKind.Ref || classType.kind === TypeKind.Ptr)) ? classType.typeReturn : classType;
			const fieldNames = (innerType !== null && innerType.typeNames !== null) ? innerType.typeNames : null as unknown as string[];
			let fi = 0;
			while (fi < d.newArguments.length) {
				const fieldVal = genExpr(g, p, d.newArguments[fi]);
				const fieldName = (fieldNames !== null && fi < fieldNames.length) ? mangleFieldName(fieldNames[fi]) : ("_f" + fi);
				emitStmtsLine(p, "(*" + tmp + ")." + fieldName + " = " + fieldVal + ";");
				fi += 1;
			}
			results.push(tmp);
		}
		return;
	}

	// Fallback
	results.push("/* unsupported expression: kind=" + kind.toString() + " */");
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

	// Reference parity: closure call generation (standard reference patterns)
	// routes closure calls to a separate handler, direct calls to prefix calls.
	// Closure calls never generate forward declarations.
	// closureCallMarker sets isDirectCall=false for closure-typed callees.
	if (!cd.isDirectCall) {
		// TAG_CALL_CLOSURE: callee + args, handled by genClosureCall inline
		const n = 1 + cd.arguments.length;
		workStack.push({ node, phase: 1, childCount: n, tag: TAG_CALL_CLOSURE });
		let i = cd.arguments.length - 1;
		while (i >= 0) {
			workStack.push({ node: cd.arguments[i], phase: 0, childCount: 0, tag: 0 });
			i -= 1;
		}
		workStack.push({ node: cd.callee, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// TAG_CALL_DIRECT: callee + args
	const n = 1 + cd.arguments.length;
	workStack.push({ node, phase: 1, childCount: n, tag: TAG_CALL_DIRECT });
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
			// For assignment LHS, prefer the variable's declared type over narrowed nodeType.
			// Parity: Nim's genAsgn uses le.typ (declared type via PSym.typ, never narrowed).
			// Our checker stores narrowed types on nodeType, so we read resolvedSym.symbolType.
			let leftType = d.left.nodeType;
			if (d.left.resolvedSym !== null && d.left.resolvedSym.symbolType !== null) {
				leftType = d.left.resolvedSym.symbolType;
			}
			const leftCType = getTypeDesc(g, leftType);
			const rightCType = getTypeDesc(g, d.right.nodeType);
			if (leftCType !== rightCType && leftCType !== "void*" && rightCType !== "void") {
				const destIsPtr = leftCType.indexOf("*") >= 0;
				const srcIsPtr = rightCType.indexOf("*") >= 0;
				if (destIsPtr === srcIsPtr) {
					finalRight = "((" + leftCType + ")(" + right + "))";
				}
			}
		}
		// Null assignment to value type: x = MS_NIL → memset(&x, 0, sizeof(Type))
		// Reference parity: value types can't be nil — zero-init instead.
		if (d.operator === "=" && (finalRight === "MS_NIL" || finalRight === "NULL" || finalRight === "((void*)0)")) {
			const lt = d.left.nodeType;
			if (lt !== null && isNilableValueType(lt)) {
				const cType = getTypeDesc(g, lt);
				results.push("memset(&(" + left + "), 0, sizeof(" + cType + "))");
				return;
			}
		}
		// String += rewritten by stringOpLower → msStringAppend(&s, t) before codegen.
		// Struct equality handled by operatorLower → TypeName_eq() (reference parity).
		// No memcmp fallback needed — codegen never sees interface === interface.
		// Modulo on doubles requires fmod() in C (% is integer-only)
		// Integer types (int32, int64 etc.) keep native %
		if (d.operator === "%") {
			const lt = d.left.nodeType;
			const isInt = lt !== null && isIntegerType(lt);
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
		let obj = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as MemberExprData;

		// Ref array access returns void* — cast to element type for member access
		// Reference parity: record field access via dot notation
		if (d.object.nodeType !== null && isRefArrayAccessCall(d.object)) {
			const elemTypeDesc = getTypeDesc(g, d.object.nodeType);
			if (elemTypeDesc !== "void*" && elemTypeDesc !== "void") {
				let prop = d.property;
				if (prop === "length" || prop === "byteLength") prop = "len";
				else prop = mangleFieldName(prop);
				// Class/ref types: msRefArray stores void*, cast to typed ptr, use ->
				// Value struct types: typed array macro returns struct value directly, use .
				if (isPointerType(d.object.nodeType)) {
					results.push("((" + elemTypeDesc + ")" + obj + ")->" + prop);
				} else {
					results.push(obj + "." + prop);
				}
				return;
			}
		}
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
		// Class/ref types are pointers — use -> for member access
		// Check nodeType first, then resolvedSym.symbolType for identifiers
		let objIsPtr = (d.object.nodeType !== null && isPointerType(d.object.nodeType));
		if (!objIsPtr && d.object.kind === NodeKind.Identifier) {
			const idSym = d.object.resolvedSym;
			if (idSym !== null && idSym.symbolType !== null && isPointerType(idSym.symbolType)) {
				objIsPtr = true;
			}
		}
		if (objIsPtr) {
			results.push(obj + "->" + field);
		} else {
			results.push(obj + "." + field);
		}
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

		// Union handling — two directions:
		// 1. Narrowing: `unionExpr as { field: T }` → `(expr).vN` (access variant)
		// 2. Construction: `{ field: val } as UnionType` → `(Union){ .vN = (Union_vN)expr }` (wrap into variant)
		const srcType = (d.asExpr !== null) ? d.asExpr.nodeType : null;

		// Case 1: Source is Union → access variant member
		// Use getTypeDesc consistency: the type cache (first-write-wins in genUnionType)
		// ensures structurally identical variants share one C typedef. Find the first
		// variant whose cached C type matches the target — guaranteed consistent with
		// variable type declarations. Self-hosting safe (no reference identity on value types).
		if (srcType !== null && srcType.kind === TypeKind.Union && node.nodeType !== null
			&& srcType.typeChildren !== null) {
			// Ensure union type is generated (populates variant type cache)
			getTypeDesc(g, srcType);
			const targetDesc = getTypeDesc(g, node.nodeType);
			let varIdx = -1;
			let vi = 0;
			while (vi < srcType.typeChildren.length) {
				const variant = srcType.typeChildren[vi];
				if (variant !== null && getTypeDesc(g, variant) === targetDesc) {
					varIdx = vi;
					vi = srcType.typeChildren.length;
				}
				vi += 1;
			}
			if (varIdx >= 0) {
				results.push("(" + expr + ").v" + intToString(varIdx));
				return;
			}
		}

		// Case 2: Target is Union → wrap object literal into variant
		// `{ field: val } as UnionType` → `(Union){ .vN = (Union_vN){ .field = val } }`
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.Union) {
			const unionType = node.nodeType;
			const unionName = getTypeDesc(g, unionType);
			let varIdx = -1;
			if (srcType !== null && srcType.kind === TypeKind.Struct && srcType.typeNames !== null) {
				varIdx = findUnionVariant(unionType, srcType.typeNames, []);
			}
			if (varIdx < 0 && d.asExpr !== null && d.asExpr.kind === NodeKind.ObjectLiteral) {
				const litData = d.asExpr.data as ObjectLiteralData;
				if (litData.keys !== null && litData.keys.length > 0) {
					const keyArr: string[] = [litData.keys[0]];
					varIdx = findUnionVariant(unionType, keyArr, []);
				}
			}
			if (varIdx >= 0) {
				const varName = unionName + "_v" + intToString(varIdx);
				// Use pointer-based reinterpret for struct-to-struct (C can't cast between struct types)
				results.push("(" + unionName + "){ ._tag = " + intToString(varIdx) + ", .v" + intToString(varIdx) + " = *(" + varName + "*)&(" + expr + ") }");
				return;
			}
			// Empty object literal (e.g., {} as DocData for Nil/HardLine variants)
			if (d.asExpr !== null && d.asExpr.kind === NodeKind.ObjectLiteral) {
				results.push("(" + unionName + "){ ._tag = -1 }");
				return;
			}
		}

		// Standard reference implementation: generate typed function pointer cast
		// from nodeType (the callee's Function type). Codegen-only concern.
		// See reference types:getClosureType(m, typ, clHalf)
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
		// Ref array access returns void* — cast to typed pointer before deref
		// Reference parity: explicit dereference of a typed location
		const hd = node.data as ExprStmtData;
		if (isRefArrayAccessCall(hd.expr) && hd.expr.nodeType !== null) {
			const elemDesc = getTypeDesc(g, hd.expr.nodeType);
			if (elemDesc !== "void*" && elemDesc !== "void") {
				if (isPointerType(hd.expr.nodeType)) {
					// Ref element: cast void* to typed ptr, deref to struct value
					results.push("(*(" + elemDesc + ")" + inner + ")");
				} else {
					// Value struct element: macro returns struct value, no deref needed
					results.push(inner);
				}
				return;
			}
		}
		results.push("(*" + inner + ")");
		return;
	}

	// HiddenAddr — Reference parity (standard address generation)
	// Reference: if indirect location, return raw snippet (already a pointer); else &(snippet)
	if (kind === NodeKind.HiddenAddr) {
		const inner = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as ExprStmtData;
		if (d.expr.kind === NodeKind.Identifier && isIndirectParam(p, (d.expr.data as IdentifierData).name)) {
			// Indirect param: already a pointer — reference pattern returns raw snippet
			results.push(safeName((d.expr.data as IdentifierData).name));
		} else {
			results.push(safeAddrOf(g, p, inner, d.expr, node.nodeType));
		}
		return;
	}

	// HiddenStdConv / HiddenSubConv
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const inner = peekResult(results, cc, 0);
		truncResults(results, cc);
		const d = node.data as HiddenStdConvData;
		const targetC = getTypeDesc(g, d.convType);
		// Zero-copy string ↔ uint8[] bridge: pointer cast (same memory layout)
		if ((node.flags & NodeFlag.Cursor) !== 0) {
			results.push("*((" + targetC + "*)&(" + inner + "))");
			return;
		}
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
		if ((node.flags & NodeFlag.Closure) !== 0) {
			// Closure literal: (msClosure){ .fn = ..., .env = ... }
			// Standard reference pattern: env is heap-allocated via msAllocTyped, fields initialized,
			// then closure pair references the pointer.
			const fnExpr = peekResult(results, cc, 0);
			const envExpr = peekResult(results, cc, 1);
			truncResults(results, cc);
			if (envExpr === "MS_NIL" || envExpr === "NULL") {
				results.push("(msClosure){ .fn = (void*)" + fnExpr + ", .env = NULL }");
			} else {
				// Standard reference pattern: heap-allocate env struct, init fields, use pointer.
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
			// Reference-aligned: hoist struct literal to temp variable + field-by-field assignment.
			// Reference implementation (object construction): generate temporary → assign fields → use temporary.
			// Never emits inline compound literals — works with C89+ and avoids &({...}) issues.
			let cType = "";
			let isClassObj = false;
			let unionWrapName = "";
			let unionWrapIdx = -1;
			if (node.nodeType !== null) {
				if (node.nodeType.kind === TypeKind.Union && d.keys.length > 0) {
					// Union variant: determine variant type from field names
					const unionName = getTypeDesc(g, node.nodeType);
					const keyArr: string[] = [d.keys[0]];
					const varIdx = findUnionVariant(node.nodeType, keyArr, []);
					if (varIdx >= 0) {
						cType = unionName + "_v" + intToString(varIdx);
						unionWrapName = unionName;
						unionWrapIdx = varIdx;
					}
				} else if (node.nodeType.kind === TypeKind.Ref && node.nodeType.typeReturn !== null) {
					// Class type: ObjectLiteral constructs inner struct, heap-allocated
					cType = getTypeDesc(g, node.nodeType.typeReturn);
					isClassObj = true;
				} else {
					const td = getTypeDesc(g, node.nodeType);
					if (td !== "void*" && td !== "double" && td !== "void") {
						cType = td;
					}
				}
			}
			if (cType !== "") {
				// Reference pattern: allocate temp, zero-init, assign fields
				p.labels += 1;
				const tmpName = "_lit" + p.labels + "_";
				const access = isClassObj ? "->" : ".";
				if (isClassObj) {
					// Class: heap-allocate (Reference parity: managed object construction)
					emitProcLocalsLine(p, cType + "* " + tmpName + ";");
					emitStmtsLine(p, tmpName + " = (" + cType + "*)msAllocTyped(sizeof(" + cType + "), NULL);");
					emitStmtsLine(p, "memset(" + tmpName + ", 0, sizeof(" + cType + "));");
				} else {
					// Value type: stack-allocate
					emitProcLocalsLine(p, cType + " " + tmpName + ";");
					emitStmtsLine(p, "memset(&" + tmpName + ", 0, sizeof(" + cType + "));");
				}
				let i = 0;
				while (i < d.keys.length) {
					const val = peekResult(results, cc, i);
					// Skip NullLiteral fields — memset already zeroed them.
					// This avoids void* → value-type errors for self-referential pointer fields
					// where the C field is T* but the MS type is T (e.g. Type.typeReturn).
					if (d.properties[i].kind !== NodeKind.NullLiteral) {
						emitStmtsLine(p, tmpName + access + mangleFieldName(d.keys[i]) + " = " + val + ";");
					}
					i += 1;
				}
				truncResults(results, cc);
				if (unionWrapIdx >= 0) {
					// Wrap variant struct in parent union compound literal
					results.push("(" + unionWrapName + "){ ._tag = " + intToString(unionWrapIdx) + ", .v" + intToString(unionWrapIdx) + " = " + tmpName + " }");
				} else {
					results.push(tmpName);
				}
			} else {
				// Reference-aligned fallback: hoist to temp even without type info.
				// Generate anonymous struct type from field names + inferred C types.
				// Reference implementation: object construction always has type info. We approximate by using field values' types.
				p.labels += 1;
				const tmpName = "_lit" + p.labels + "_";
				// Build anonymous struct definition from values
				let structDef = "struct { ";
				let i = 0;
				while (i < d.keys.length) {
					if (i > 0) structDef = structDef + " ";
					const propNode = d.properties[i];
					let fieldType = "double";  // default
					if (propNode !== null && propNode.nodeType !== null) {
						fieldType = getTypeDesc(g, propNode.nodeType);
					}
					structDef = structDef + fieldType + " " + mangleFieldName(d.keys[i]) + ";";
					i += 1;
				}
				structDef = structDef + " }";
				emitProcLocalsLine(p, structDef + " " + tmpName + ";");
				emitStmtsLine(p, "memset(&" + tmpName + ", 0, sizeof(" + tmpName + "));");
				i = 0;
				while (i < d.keys.length) {
					const val = peekResult(results, cc, i);
					if (d.properties[i].kind !== NodeKind.NullLiteral) {
						emitStmtsLine(p, tmpName + "." + mangleFieldName(d.keys[i]) + " = " + val + ";");
					}
					i += 1;
				}
				truncResults(results, cc);
				results.push(tmpName);
			}
		}
		return;
	}

	// NewExpr handled entirely in discover phase (inline allocation)

	// Fallback
	truncResults(results, cc);
	results.push("/* unsupported expression: resolve kind=" + kind.toString() + " */");
}

// ===== genClosureCall — Standard reference parity (closure calling convention) =====
// Generates:  (cl.env) ? ((RetType(*)(Params, void*))cl.fn)(args, cl.env)
//                       : ((RetType(*)(Params))cl.fn)(args)
// env is LAST parameter (Standard reference pattern).
// No forward declarations — closure struct is self-contained.

function genClosureCall(g: CGen, p: CProc, callee: string, argsStr: string, calleeType: Type, node: Node, results: string[]): void {
	// Reference implementation pattern: extract environment and function pointers from closure pair
	const envExpr = callee + ".env";
	const fnExpr = callee + ".fn";

	// NRVO for closures: pass &dest as first param (our convention; reference uses last param)
	const nrvoRet = getCalleeReturnType(node);
	const nrvoType = (nrvoRet !== null && isNrvoReturnType(nrvoRet)) ? nrvoRet : null;

	if (nrvoType !== null) {
		// NRVO: allocate temp, pass &tmp as first arg, read tmp after call
		const cType = getTypeDesc(g, nrvoType);
		const tmp = getTemp(p, cType);
		const nrvoArg = "&" + tmp.snippet;
		let fullArgs = "";
		if (argsStr !== "") {
			fullArgs = nrvoArg + ", " + argsStr;
		} else {
			fullArgs = nrvoArg;
		}
		// Cast with NRVO-aware signature (void return, ResultType* first param)
		const clFull = genClFullCastNrvo(g, calleeType, cType);
		const clHalf = genClHalfCastNrvo(g, calleeType, cType);
		const callWithEnv = "((" + clFull + ")" + fnExpr + ")(" + fullArgs + ", " + envExpr + ")";
		const callNoEnv = "((" + clHalf + ")" + fnExpr + ")(" + fullArgs + ")";
		emitStmtsLine(p, "(" + envExpr + " ? " + callWithEnv + " : " + callNoEnv + ");");
		results.push(tmp.snippet);
		return;
	}

	// Non-NRVO: inline expression form
	const clFull = genClFullCast(g, calleeType);
	const clHalf = genClHalfCast(g, calleeType);

	// With env: fn(args..., env) — env LAST
	let callWithEnv = "";
	if (argsStr !== "") {
		callWithEnv = "((" + clFull + ")" + fnExpr + ")(" + argsStr + ", " + envExpr + ")";
	} else {
		callWithEnv = "((" + clFull + ")" + fnExpr + ")(" + envExpr + ")";
	}

	// Without env: ((cast)fn)(args...)
	let callNoEnv = "";
	if (argsStr !== "") {
		callNoEnv = "((" + clHalf + ")" + fnExpr + ")(" + argsStr + ")";
	} else {
		callNoEnv = "((" + clHalf + ")" + fnExpr + ")()";
	}

	// Reference parity: procedure call dispatch
	// Closure calls generate inline if/else dispatch on env != NULL.
	results.push("(" + envExpr + " ? " + callWithEnv + " : " + callNoEnv + ")");
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
				arg = safeAddrOf(g, p, arg, cd.arguments[ai], null);
			} else if (hasOvParams && ai < ovType.typeChildren.length && ai < cd.arguments.length) {
				const paramType = ovType.typeChildren[ai];
				const argNode = cd.arguments[ai];
				if (paramType !== null && argNode.nodeType !== null && argNode.kind !== NodeKind.HiddenAddr) {
					const paramIsPtr = isPointerType(paramType);
					const argIsPtr = isPointerType(argNode.nodeType);
					const paramCcgPtr = ccgIntroducedPtr(paramType);
					// Reference parity: nil passed to ref/ptr param is already a valid pointer — no &
					if (paramIsPtr && !argIsPtr && argNode.kind !== NodeKind.NullLiteral) {
						arg = safeAddrOf(g, p, arg, argNode, paramType);
					} else if (!paramIsPtr && argIsPtr && !paramCcgPtr) {
						// Only deref if param is NOT ccgIntroducedPtr'd
						// Self-ref fields are auto-promoted to Ref<T> (argIsPtr=true)
						// but ccgIntroducedPtr params expect T* — pass pointer directly
						arg = "*(" + arg + ")";
					}
					// Reference parity: introduced pointer params use address location patterns
					if (!paramIsPtr && !argIsPtr && paramCcgPtr) {
						arg = genArgCcgPtr(g, arg, argNode, p);
					}
				} else if (paramType !== null && argNode.nodeType === null && arg.length > 0 && arg.charCodeAt(0) === "{".code) {
					// Untyped ObjectLiteral — use paramType to hoist properly
					arg = safeAddrOf(g, p, arg, argNode, paramType);
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
		const ovIdx = idx >= 0 ? idx : 0;
		const ovCalleeName = mangledFunctionName(sym, sym.name, ovIdx);
		// On-demand cross-module prototype (reference parity: genProcPrototype)
		ensureCrossModuleProto(g, ovCalleeName, ovType, sym);
		results.push(ovCalleeName + "(" + argsStr + ")");
		return;
	}

	// Direct or closure: first child is callee, rest are args
	const callee = peekResult(results, cc, 0);
	// C varargs: msNumberArrayFrom(count, (double)(e1), ...) — va_arg reads 8 bytes for double
	const isNumberArrayFrom = callee === "msNumberArrayFrom";
	// Resolve callee's function type for parameter type checking
	const calleeType = sym !== null && sym.symbolType !== null ? sym.symbolType : (cd.callee.nodeType !== null ? cd.callee.nodeType : null);
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
					const paramCcgPtr = ccgIntroducedPtr(paramType);
					// Reference parity: nil passed to ref/ptr param is already a valid pointer — no &
					if (paramIsPtr && !argIsPtr && argNode.kind !== NodeKind.NullLiteral) {
						arg = safeAddrOf(g, p, arg, argNode, paramType);
					} else if (!paramIsPtr && argIsPtr && !paramCcgPtr) {
						// Only deref if param is NOT ccgIntroducedPtr'd
						// Self-ref fields are auto-promoted to Ref<T> (argIsPtr=true)
						// but ccgIntroducedPtr params expect T* — pass pointer directly
						arg = "*(" + arg + ")";
					}
					// Reference parity: introduced pointer params use address location patterns
					if (!paramIsPtr && !argIsPtr && paramCcgPtr) {
						arg = genArgCcgPtr(g, arg, argNode, p);
					}
				} else if (paramType !== null && argNode.nodeType === null && arg.length > 0 && arg.charCodeAt(0) === "{".code) {
					// Untyped ObjectLiteral — use paramType to hoist properly
					arg = safeAddrOf(g, p, arg, argNode, paramType);
				}
			}
		}
		argsStr = argsStr + arg;
		i += 1;
	}
	truncResults(results, cc);

	// ===== Reference parity: closure call (standard reference pattern) =====
	// Closure calls generate inline if/else dispatch on env != NULL.
	// No forward declarations — closure is a self-contained struct value.
	if (tag === TAG_CALL_CLOSURE) {
		genClosureCall(g, p, callee, argsStr, calleeType, node, results);
		return;
	}

	// ===== genPrefixCall (TAG_CALL_DIRECT) =====
	// On-demand cross-module prototype (reference parity: genProcPrototype)
	const protoSym = sym !== null ? sym : (cd.callee.resolvedSym !== null ? cd.callee.resolvedSym : null as unknown as Symbol);
	const protoType = protoSym !== null && protoSym.symbolType !== null ? protoSym.symbolType : calleeType;
	ensureCrossModuleProto(g, callee, protoType, protoSym);
	// DRC hooks — emit forward declaration on-demand
	ensureDrcProto(g, callee);

	const calleeStr = callee;
	// NRVO: call returns void, result via out-param
	const nrvoRet = getCalleeReturnType(node);
	const nrvoType = (nrvoRet !== null && isNrvoReturnType(nrvoRet)) ? nrvoRet : null;
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
		const firstArg = genExpr(g, p, args[0]);
		let result = cName + "(" + safeAddrOf(g, p, firstArg, args[0], null);
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

import { createCGen, createProc, extract, sec, CSection, typeCacheGet, isIndirectParam } from "./context";
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
	const p = createProc("test");
	return genExpr(g, p, es.expr);
}

test "integer" { assert exprSnippet("42;") === "42"; }

test "float" { assert exprSnippet("3.14;") === "3.14"; }

test "zero" { assert exprSnippet("0;") === "0"; }

test "simple string uses pool ref" {
	const result = exprSnippet("\"hello\";");
	assert result === "MS_STRING_LIT(&TMP_STR_1, 5)";
}

test "true" { assert exprSnippet("true;") === "MS_TRUE"; }

test "false" { assert exprSnippet("false;") === "MS_FALSE"; }

test "null literal" { assert exprSnippet("null;") === "MS_NIL"; }

test "simple name" { assert exprSnippet("foo;") === "foo"; }

test "addition" { assert exprSnippet("a + b;") === "(a + b)"; }

test "equality" { assert exprSnippet("x === y;") === "(x == y)"; }

test "not equal" { assert exprSnippet("x !== y;") === "(x != y)"; }

test "nested" { assert exprSnippet("a + b * c;") === "(a + (b * c))"; }

test "negation" { assert exprSnippet("-x;") === "(-x)"; }

test "logical not" { assert exprSnippet("!flag;") === "(!flag)"; }

test "no args" { assert exprSnippet("foo();") === "foo()"; }

test "with args" { assert exprSnippet("foo(a, b);") === "foo(a, b)"; }

test "nested call" { assert exprSnippet("foo(bar(x));") === "foo(bar(x))"; }

test "dot access" { assert exprSnippet("obj.x;") === "obj.x"; }

test "bracket access" { assert exprSnippet("arr[0];") === "arr[0]"; }

test "expression index" { assert exprSnippet("arr[i + 1];") === "arr[(i + 1)]"; }

test "conditional" { assert exprSnippet("a ? b : c;") === "(a ? b : c)"; }

test "empty array" {
	// Without nodeType, falls back to generic msRefArray
	assert exprSnippet("[];") === "(msRefArray){0}";
}

test "array with elements no type" {
	// Without nodeType (no checker), falls back to temp + push
	const result = exprSnippet("[1, 2, 3];");
	// Returns temp name (setup emitted to proc stmts)
	assert result.length > 0;
}

test "postfix increment" { assert exprSnippet("x++;") === "(x++)"; }

test "prefix increment" { assert exprSnippet("++x;") === "(++x)"; }

test "postfix decrement" { assert exprSnippet("x--;") === "(x--)"; }

test "prefix decrement" { assert exprSnippet("--x;") === "(--x)"; }

test "simple new" { assert exprSnippet("new Foo();") === "(Foo*)msAllocTyped(sizeof(Foo), &Foo_typeInfo)"; }

test "new with args" { assert exprSnippet("new Bar(1, 2);") === "_new1_"; }

test "move identifier" { assert exprSnippet("move x;") === "x"; }

test "move call" { assert exprSnippet("move f();") === "f()"; }

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
	assert result.length > 0;
	// Innermost pair should be (a + a)
	let hasInner = false;
	let j = 0;
	while (j < result.length - 7) {
		if (sliceStr(result, j, j + 7) === "(a + a)") {
			hasInner = true;
		}
		j += 1;
	}
	assert hasInner;
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
	assert result.length > 0;
	// Should contain f(f( pattern
	let hasNested = false;
	let j = 0;
	while (j < result.length - 4) {
		if (sliceStr(result, j, j + 4) === "f(f(") {
			hasNested = true;
		}
		j += 1;
	}
	assert hasNested;
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
	assert result.length > 0;
}
