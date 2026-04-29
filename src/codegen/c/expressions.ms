// C Codegen — Expression Emission
//
// genExpr returns a C code snippet string for any expression node.
// genExprToLoc fills a CLoc dest (for statement-level assignment).
//
// Follows standard reference implementation pattern for destination carriers.
// MetaScript value-type interfaces (CLoc passed by value → use return).

import { Node, NodeKind, NodeFlag, NumberLiteralData, StringLiteralData, BooleanLiteralData, IdentifierData, BinaryExprData, UnaryExprData, MemberExprData, ArrayAccessData, ConditionalExprData, TypeAssertionData, CallExprData, ObjectLiteralData, ArrayLiteralData, UpdateExprData, NewExprData, MoveExprData, SpreadExprData, ExprStmtData, HiddenStdConvData, ClassDeclData, PropertyDeclData, Type, TypeKind, Symbol, SymbolKind } from "../../ast/node";
import { isIntegerType, isFloatType, getProperty, findUnionVariant, isDiscriminatedUnion, findVariantByFieldName, findVariantByDiscriminant, getDiscriminantName, voidType, isStringLike, awaitedType, unwrapRefNullUnion } from "../../checker/types";
import { SymbolFlag, hasFlag } from "../../checker/symbol";
import {
	CGen, CProc, CLoc, CLocKind, CStorageLoc, CSection, rdLoc, addLine, sec,
	pStmts, getTemp, nameSetHas, nameSetAdd, emitStmtsLine, internString,
	emitProcLocalsLine, lookupLocalName,
} from "./context";
import { mangle, mangleFieldName, mangledFunctionName, mangledGlobalName, isModuleGlobalVar, safeName, staticFieldCName } from "./names";
import { getTypeDesc, isNrvoReturnType, getCalleeReturnType, getCalleeFuncType, isPointerType, isNilableValueType, annotationToC, genClHalfCast, genClFullCast, genClHalfCastNrvo, genClFullCastNrvo, shouldIndirectParam, ensureTypeInfo, ensureTypeInfoDef, ensureForwardDecl, getArrayContentType, ensurePromiseAllInstance } from "./types";
import { formatCNumber, cBoolLiteral, cNullLiteral, msStringPoolRef, cStringByteLen } from "./literals";
import { findChar } from "../../utils/string";
import { ensureDrcProto, ensureCrossModuleProto, isDrcLifecycleName } from "./forward";
import { useHeader } from "./context";
import { GcMode } from "../../checker/context";

// Build a msAllocTyped/msAllocTypedUninit call expression. Under --gc=manual,
// TypeInfo is not emitted so we pass NULL; otherwise we reference the type's
// TypeInfo global.
// Strip Sink/Lent ownership modifiers — codegen treats them as transparent wrappers.
function resolveSinkLent(t: Type | null): Type | null {
	if (t === null) return null;
	if (t.kind === TypeKind.Sink || t.kind === TypeKind.Lent) {
		return t.typeReturn;
	}
	return t;
}

// Unwrap Ptr/Ref/Sink/Lent to expose the inner Union for variant→union pointer casts.
function unwrapPointerLikeForVariant(t: Type | null): Type | null {
	if (t === null) return null;
	const k = t.kind;
	if ((k === TypeKind.Ptr || k === TypeKind.Ref
		|| k === TypeKind.Sink || k === TypeKind.Lent) && t.typeReturn !== null) {
		return t.typeReturn;
	}
	return t;
}

function genAllocCall(g: CGen, cType: string, fn: string): string {
	const typeArg = (g.checkerCtx !== null && g.checkerCtx.gcMode === GcMode.Manual) ? "NULL" : `&${cType}TypeInfo`;
	return `(${cType}*)${fn}(sizeof(${cType}), ${typeArg})`;
}

// Safe default — header + payload zero-initialised. Matches Nim nimNewObj.
function genAllocTyped(g: CGen, cType: string): string {
	return genAllocCall(g, cType, "msAllocTyped");
}

// Uninit opt-in: payload stays dirty. Emit ONLY at sites that provably write
// every payload byte before the next read (e.g. new T(args) with
// args.length === typeNames.length). Mirrors Nim nimNewObjUninit.
function genAllocTypedUninit(g: CGen, cType: string): string {
	return genAllocCall(g, cType, "msAllocTypedUninit");
}

// Pick safe alloc vs Uninit. Uninit requires both: (1) caller already proved
// every field is written before the next read, (2) no inherited fields —
// typeExtra !== null means the class inherits, and inherited fields are NOT
// in typeNames so coverage can't be proved. Default to safe on any doubt.
function pickAllocExpr(g: CGen, cType: string, innerType: Type | null, argsCoverAllFields: boolean): string {
	const hasBase = innerType !== null && innerType.typeExtra !== null;
	const safeUninit = !hasBase && argsCoverAllFields;
	return safeUninit ? genAllocTypedUninit(g, cType) : genAllocTyped(g, cType);
}

// ===== Reference: argument passing for introduced pointers =====
// Wraps arg for pointer introduction params at call sites.
// Reference: initLocExpr → addAddrLoc patterns.
//
// addrLoc: if NOT indirect → &(snippet); if indirect → snippet (already a pointer)
//
// Our Identifier handler already applies rdLoc (pushes (*name) for indirect params).
// So for indirect args: snippet on stack = (*name), but we need raw pointer = name.
// We use the raw safeName directly (the reference implementation's snippet is always the raw name).
// Check if a class type has instance fields with default initializers
function hasInstanceFieldDefaults(classType: Type): boolean {
	if (classType === null) return false;
	const classSym = classType.sym;
	if (classSym === null || classSym.declNode === null) return false;
	const cd = classSym.declNode.data as ClassDeclData;
	for (const member of cd.classBody) {
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			if (!pd.propIsStatic && pd.propInitializer !== null) return true;
		}
	}
	return false;
}

// Emit instance field default initializers for fields not covered by constructor args
function emitInstanceFieldDefaults(g: CGen, p: CProc, tmp: string, classType: Type, argCount: number): void {
	if (classType === null) return;
	const classSym = classType.sym;
	if (classSym === null || classSym.declNode === null) return;
	const cd = classSym.declNode.data as ClassDeclData;
	let fieldIdx = 0;
	for (const member of cd.classBody) {
		if (member.kind === NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			if (!pd.propIsStatic) {
				if (pd.propInitializer !== null && fieldIdx >= argCount) {
					// Propagate declared property type to untyped initializer so codegen
					// (e.g., genArrayLiteral) can choose the correct C type instead of
					// defaulting to msRefArray for empty array literals.
					if (pd.propInitializer.nodeType === null && member.nodeType !== null) {
						pd.propInitializer.nodeType = member.nodeType;
					}
					const initVal = genExpr(g, p, pd.propInitializer);
					emitStmtsLine(p, `${tmp}->${mangleFieldName(pd.propName)} = ${initVal};`);
				}
				fieldIdx += 1;
			}
		}
	}
}

// Check if a node is effectively null — unwraps TypeAssertion chains (e.g., `null as unknown as T`).
function isNullExpr(node: Node): boolean {
	let cur = node;
	while (cur.kind === NodeKind.TypeAssertion) {
		cur = (cur.data as TypeAssertionData).asExpr;
	}
	return cur.kind === NodeKind.NullLiteral;
}

// Check if a node is a CallExpr("msRefArrayAccess", ...) — used by MemberExpr and HiddenDeref
// to handle void* results from ref array macros. Returns true if the node matches.
function isRefArrayAccessCall(node: Node): boolean {
	if (node.kind !== NodeKind.CallExpr) return false;
	const callee = (node.data as CallExprData).callee;
	return callee.kind === NodeKind.Identifier && (callee.data as IdentifierData).name === "msRefArrayAccess";
}

// Shared ABI shim for call arguments — reference parity: genArg
// Single point for struct-aware pointer promotion, pointer/value conversion, and untyped literal handling.
// mutBits/paramIdx: callee's sym.mutatedParams bitfield + param index for struct-aware promotion.
export function shimCallArg(g: CGen, p: CProc, arg: string, paramType: Type, argNode: Node, mutBits: int32, paramIdx: number): string {
	if (paramType !== null && argNode.kind !== NodeKind.HiddenAddr) {
		const paramIsPtr = isPointerType(paramType);
		const isMutated = (mutBits & (1 << (paramIdx as int32))) !== 0;
		const paramCcgPtr = shouldIndirectParam(paramType, isMutated);
		if (argNode.nodeType !== null) {
			// Full type info: check pointer/value mismatch + ccgIntroducedPtr
			let argIsPtr = isPointerType(argNode.nodeType);
			if (!argIsPtr && argNode.resolvedSym !== null && argNode.resolvedSym.symbolType !== null) {
				argIsPtr = isPointerType(argNode.resolvedSym.symbolType);
			}
			if (paramIsPtr && !argIsPtr && !isNullExpr(argNode)) {
				return safeAddrOf(g, p, arg, argNode, paramType);
			} else if (!paramIsPtr && argIsPtr && !paramCcgPtr) {
				return `*(${arg})`;
			}
			if (!paramIsPtr && !argIsPtr && paramCcgPtr) {
				return genArgCcgPtr(g, arg, argNode, p, paramType);
			}
		} else {
			// No arg type — genArg pattern: decide promotion from param type alone
			if (!paramIsPtr && paramCcgPtr) {
				return genArgCcgPtr(g, arg, argNode, p, paramType);
			}
			if (arg.byteLength > 0 && arg.byteAt(0) === "{".code) {
				return safeAddrOf(g, p, arg, argNode, paramType);
			}
		}
	}
	return arg;
}

export function genArgCcgPtr(g: CGen, arg: string, argNode: Node, p: CProc, paramType: Type): string {
	if (argNode.kind === NodeKind.Identifier && isIndirectParam(p, (argNode.data as IdentifierData).name)) {
		// Indirect param: already a pointer — pass raw (reference patterns return snippet as-is)
		return safeName((argNode.data as IdentifierData).name);
	}
	// Not indirect: take address — use safeAddrOf to handle bare compound literals
	return safeAddrOf(g, p, arg, argNode, paramType);
}

// Check if a CallExpr calls an msArrayAccess-family macro (produces C lvalue).
// nativeLower rewrites arr[i] to CallExpr("msArrayAccess", [arr, i]).
// These macros expand to *(&data[idx]) which IS an lvalue in C.
function isArrayAccessCall(node: Node): boolean {
	if (node === null || node.kind !== NodeKind.CallExpr) return false;
	const callee = (node.data as CallExprData).callee;
	if (callee.kind !== NodeKind.Identifier) return false;
	const name = (callee.data as IdentifierData).name;
	return name === "msArrayAccess" || name === "msStringArrayAccess"
		|| name === "msNumberArrayAccess" || name === "msRefArrayAccess"
		|| name === "msUint8ArrayAccess" || name === "msSizedArrayAccess";
}

// Check if an AST node produces a C lvalue (can have & applied directly).
// Identifiers, member access, array subscripts, and pointer derefs are lvalues.
// CallExpr to msArrayAccess macros also produce lvalues (nativeLower rewrites arr[i] to these).
// Everything else (calls, literals, conditionals, casts) needs hoisting to a temp.
function isLvalueNode(node: Node): boolean {
	if (node === null) return false;
	return node.kind === NodeKind.Identifier
		|| node.kind === NodeKind.MemberExpr
		|| node.kind === NodeKind.ArrayAccess
		|| node.kind === NodeKind.HiddenDeref
		|| isArrayAccessCall(node);
}

// Reference parity: standard address generation always operates on a named variable,
// never on a bare compound literal. When we need &(expr) and expr is a bare
// compound literal (starts with '{'), hoist it to a temp variable first.
// Reference-aligned address-of: always operates on named locations.
// paramType: optional parameter type from call site for resolving untyped literals.
export function safeAddrOf(g: CGen, p: CProc, snippet: string, exprNode: Node, paramType: Type | null): string {
	if (snippet.byteLength > 0 && snippet.byteAt(0) === "{".code) {
		// Bare compound literal — must hoist to temp (Reference: generate temporary + field assignment)
		let cType = "";
		// Try 1: exprNode.nodeType
		if (exprNode !== null && exprNode.nodeType !== null) {
			if (exprNode.nodeType.kind === TypeKind.Union) {
				const od = exprNode.data as ObjectLiteralData;
				if (od.keys !== null && od.keys.length > 0) {
					const unionName = getTypeDesc(g, exprNode.nodeType);
					// Use checker-stamped variant index (reference parity: codegen reads, never re-determines)
					const stamped = ((exprNode.flags >> 16) & 65535) as int32;
					let varIdx = stamped > 0 ? stamped - 1 : -1;
					// Fallback for unchecked nodes (transform-generated)
					if (varIdx < 0) {
						const keyArr: string[] = [];
						const typeArr: Type[] = [];
						for (let ki = 0; ki < od.keys.length; ki += 1) {
							keyArr.push(od.keys[ki]);
							if (ki < od.properties.length && od.properties[ki] !== null && od.properties[ki].nodeType !== null) {
								typeArr.push(od.properties[ki].nodeType);
							}
						}
						varIdx = findUnionVariant(exprNode.nodeType, keyArr, typeArr);
						if (varIdx < 0 && typeArr.length > 0) {
							varIdx = findUnionVariant(exprNode.nodeType, keyArr, []);
						}
					}
					if (varIdx >= 0) {
						// Wrap in full union type so &temp is NodeData*, not variant*
						p.labels += 1;
						const tmpName = `_clit${p.labels}_`;
						const varTypeName = `${unionName}_v${varIdx}`;
						emitProcLocalsLine(p, `${unionName} ${tmpName};`);
						emitStmtsLine(p, `${tmpName}._tag = ${varIdx};`);
						emitStmtsLine(p, `${tmpName}.v${varIdx} = (${varTypeName})${snippet};`);
						return "&" + tmpName;
					}
				}
			} else {
				cType = getTypeDesc(g, exprNode.nodeType);
			}
		}
		// Try 2: paramType (pointer type → strip * to get pointee)
		if ((cType === "" || cType === "void" || cType === "void*") && paramType !== null) {
			// Unwrap pointer/ownership modifiers to get inner type
			let innerType = paramType;
			if (paramType.kind === TypeKind.Ptr || paramType.kind === TypeKind.Ref
				|| paramType.kind === TypeKind.Sink || paramType.kind === TypeKind.Lent) {
				innerType = paramType.typeReturn;
			}
			if (innerType !== null && innerType.kind === TypeKind.Union && exprNode !== null && exprNode.kind === NodeKind.ObjectLiteral) {
				// Union variant: use checker-stamped index, fallback to field matching
				const od = exprNode.data as ObjectLiteralData;
				if (od.keys !== null && od.keys.length > 0) {
					const unionName = getTypeDesc(g, innerType);
					const stamped = ((exprNode.flags >> 16) & 65535) as int32;
					let varIdx = stamped > 0 ? stamped - 1 : -1;
					if (varIdx < 0) {
						const keyArr: string[] = [];
						const typeArr: Type[] = [];
						for (let ki = 0; ki < od.keys.length; ki += 1) {
							keyArr.push(od.keys[ki]);
							if (ki < od.properties.length && od.properties[ki] !== null && od.properties[ki].nodeType !== null) {
								typeArr.push(od.properties[ki].nodeType);
							}
						}
						varIdx = findUnionVariant(innerType, keyArr, typeArr);
						if (varIdx < 0 && typeArr.length > 0) {
							varIdx = findUnionVariant(innerType, keyArr, []);
						}
					}
					if (varIdx >= 0) {
						// Emit as full union with tag + variant
						p.labels += 1;
						const tmpName = `_clit${p.labels}_`;
						emitProcLocalsLine(p, `${unionName} ${tmpName};`);
						emitStmtsLine(p, `${tmpName}._tag = ${varIdx};`);
						const varTypeName = `${unionName}_v${varIdx}`;
						emitStmtsLine(p, `${tmpName}.v${varIdx} = (${varTypeName})${snippet};`);
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
			const tmpName = `_clit${p.labels}_`;
			emitProcLocalsLine(p, `${cType} ${tmpName};`);
			emitStmtsLine(p, `${tmpName} = (${cType})${snippet};`);
			return "&" + tmpName;
		}
	}
	// Union variant wrapping: when passing a variant-typed temp where a union* is expected,
	// wrap in a full union with tag. This handles _litN_ temps from ObjectLiteral emission.
	// Use paramType for union detection when nodeType is null (parser-created nodes).
	if (paramType !== null && paramType.kind === TypeKind.Union && exprNode !== null && exprNode.kind === NodeKind.ObjectLiteral) {
		const od = exprNode.data as ObjectLiteralData;
		if (od.keys !== null && od.keys.length > 0) {
			const unionName = getTypeDesc(g, paramType);
			// Use checker-stamped variant index
			const stamped = ((exprNode.flags >> 16) & 65535) as int32;
			let varIdx = stamped > 0 ? stamped - 1 : -1;
			if (varIdx < 0) {
				const keyArr: string[] = [];
				const typeArr: Type[] = [];
				for (let ki = 0; ki < od.keys.length; ki += 1) {
					keyArr.push(od.keys[ki]);
					if (ki < od.properties.length && od.properties[ki] !== null && od.properties[ki].nodeType !== null) {
						typeArr.push(od.properties[ki].nodeType);
					}
				}
				varIdx = findUnionVariant(paramType, keyArr, typeArr);
				if (varIdx < 0 && typeArr.length > 0) {
					varIdx = findUnionVariant(paramType, keyArr, []);
				}
			}
			if (varIdx >= 0) {
				p.labels += 1;
				const tmpName = `_clit${p.labels}_`;
				const varTypeName = `${unionName}_v${varIdx}`;
				emitProcLocalsLine(p, `${unionName} ${tmpName};`);
				emitStmtsLine(p, `${tmpName}._tag = ${varIdx};`);
				emitStmtsLine(p, `${tmpName}.v${varIdx} = (${varTypeName})${snippet};`);
				return "&" + tmpName;
			}
		}
	}
	// Fallback: non-lvalue expressions (calls, constructors) cannot have & applied directly.
	// Hoist to a temp local so we can take its address.
	if (p !== null && exprNode !== null && !isLvalueNode(exprNode)) {
		// When paramType (from implementation) resolves to a Union but exprNode.nodeType
		// is a Struct variant (from overload), wrap in the full tagged union.
		const resolvedParam = resolveSinkLent(paramType);
		const exprNT = exprNode.nodeType;
		if (resolvedParam !== null && resolvedParam.kind === TypeKind.Union
			&& exprNT !== null && exprNT.kind === TypeKind.Struct
			&& exprNode.kind === NodeKind.ObjectLiteral) {
			const unionName = getTypeDesc(g, resolvedParam);
			const variantType = getTypeDesc(g, exprNT);
			// Find variant index by matching the Struct in the Union's typeChildren
			let varIdx = -1;
			let vi = 0;
			while (vi < resolvedParam.typeChildren.length) {
				if (getTypeDesc(g, resolvedParam.typeChildren[vi]) === variantType) { varIdx = vi; }
				vi = vi + 1;
			}
			if (varIdx >= 0 && unionName !== "") {
				p.labels += 1;
				const tmpName = `_clit${p.labels}_`;
				emitProcLocalsLine(p, `${unionName} ${tmpName};`);
				emitStmtsLine(p, `${tmpName}._tag = ${varIdx};`);
				emitStmtsLine(p, `${tmpName}.v${varIdx} = ${snippet};`);
				return "&" + tmpName;
			}
		}
		let cType = "";
		if (exprNode.nodeType !== null) {
			cType = getTypeDesc(g, exprNode.nodeType);
		} else if (paramType !== null) {
			cType = getTypeDesc(g, paramType);
		}
		if (cType !== "" && cType !== "void" && cType !== "void*") {
			p.labels += 1;
			const tmpName = `_clit${p.labels}_`;
			emitProcLocalsLine(p, `${cType} ${tmpName};`);
			emitStmtsLine(p, `${tmpName} = ${snippet};`);
			return "&" + tmpName;
		}
	}
	// Union variant lvalue: when &local is taken and the local's type is a variant struct
	// (e.g. NodeData_v11) while the parameter expects the base union pointer (NodeData*),
	// cast to the union type. The checker types the local as the declared variant type
	// (correct), and the codegen maps it to the variant struct (correct). The pointer
	// widening (variant* → union*) must happen here at the conversion point — same pattern
	// as the compound literal union wrapping above (lines 183-213).
	if (paramType !== null && exprNode !== null && exprNode.nodeType !== null) {
		const innerParam = unwrapPointerLikeForVariant(paramType);
		const exprNT = exprNode.nodeType;
		if (innerParam !== null && innerParam.kind === TypeKind.Union && exprNT.kind === TypeKind.Struct) {
			const unionCType = getTypeDesc(g, innerParam);
			return `(${unionCType}*)&(${snippet})`;
		}
	}
	return `&(${snippet})`;
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

// Evaluation context for iterative genExpr — class ensures reference semantics
// so helper functions share the same arrays instead of getting value copies.
class ExprEvalCtx {
	workStack: ExprStackItem[];
	results: string[];
}

const TAG_DEFAULT = 0;
const TAG_CALL_OVERLOAD = 2;
const TAG_CALL_DIRECT = 3;
const TAG_CALL_CLOSURE = 4;  // Reference parity: closure calls — separate path, no forward declarations

// Read i-th child from top N results on the stack.
function peekResult(ctx: ExprEvalCtx, childCount: number, idx: number): string {
	return ctx.results[ctx.results.length - childCount + idx];
}

// Remove top N results from the stack.
function truncResults(ctx: ExprEvalCtx, count: number): void {
	let i = 0;
	while (i < count) {
		ctx.results.pop();
		i += 1;
	}
}

// Emit `msString _tmp[n];` + `_tmp[i] = <arg>;` fills for a stack-local string
// array from child results [partsStart..cc). Returns the tmp var name.
// Shared by msStringConcatArr / msStringArrayFromArr / msStringAppendArr intercepts.
function emitStringArrayLocal(g: CGen, p: CProc, ctx: ExprEvalCtx, cc: number, partsStart: number, prefix: string): string {
	const n = cc - partsStart;
	g.labels += 1;
	const tmpName = `${prefix}${g.labels}_`;
	emitProcLocalsLine(p, `msString ${tmpName}[${n}];`);
	let ai = 0;
	while (ai < n) {
		const argStr = peekResult(ctx, cc, ai + partsStart);
		emitStmtsLine(p, `${tmpName}[${ai}] = ${argStr};`);
		ai += 1;
	}
	return tmpName;
}

// Comma-join top N results from the stack, then remove them.
function joinChildResults(ctx: ExprEvalCtx, count: number): string {
	let s = "";
	let i = 0;
	while (i < count) {
		if (i > 0) s = s + ", ";
		s = s + ctx.results[ctx.results.length - count + i];
		i += 1;
	}
	truncResults(ctx, count);
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
	const ctx: ExprEvalCtx = { workStack: [], results: [] };
	ctx.workStack.push({ node, phase: 0, childCount: 0, tag: 0 });
	while (ctx.workStack.length > 0) {
		const item = ctx.workStack[ctx.workStack.length - 1];
		ctx.workStack.pop();
		if (item.phase === 0) {
			discoverExpr(g, p, item.node, ctx);
		} else {
			emitExpr(g, p, item, ctx);
		}
	}
	if (ctx.results.length === 0) return "MS_NIL";
	return ctx.results[ctx.results.length - 1];
}

// ===== Discover phase: push leaf results or Emit + children =====

function discoverExpr(g: CGen, p: CProc, node: Node, ctx: ExprEvalCtx): void {
	if (node === null) {
		ctx.results.push("MS_NIL");
		return;
	}
	const kind = node.kind;

	// Leaf nodes — push result directly, no Emit needed
	if (kind === NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		ctx.results.push(formatCNumber(d.value));
		return;
	}
	if (kind === NodeKind.StringLiteral) {
		const d = node.data as StringLiteralData;
		// Single ASCII char: use interned char table (zero alloc, pointer identity)
		const byteLen = cStringByteLen(d.value);
		if (byteLen === 1 && d.value.byteLength === 1) {
			const code = d.value.byteAt(0);
			if (code < 128) {
				ctx.results.push(`msCharTable[${code}]`);
				return;
			}
		}
		const poolName = internString(g.stringPool, d.value);
		ctx.results.push(msStringPoolRef(poolName, byteLen));
		return;
	}
	if (kind === NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		ctx.results.push(cBoolLiteral(d.boolValue));
		return;
	}
	if (kind === NodeKind.NullLiteral) {
		// Reference getDefaultValue() pattern: emit type-appropriate zero value.
		// Primitives → 0/0.0/false, value types → {0}, pointers → NULL.
		if (node.nodeType !== null) {
			const nk = node.nodeType.kind;
			if (nk === TypeKind.Number || nk === TypeKind.Float64 || nk === TypeKind.Float32) {
				ctx.results.push("0.0");
				return;
			}
			if (nk === TypeKind.Int8 || nk === TypeKind.Int16 || nk === TypeKind.Int32 || nk === TypeKind.Int64
				|| nk === TypeKind.Uint8 || nk === TypeKind.Uint16 || nk === TypeKind.Uint32 || nk === TypeKind.Uint64) {
				ctx.results.push("0");
				return;
			}
			if (nk === TypeKind.Boolean) {
				ctx.results.push("MS_FALSE");
				return;
			}
			// Union(Ref<T>, Null) / Union(Ptr<T>, Null) is a pointer at C level — emit NULL,
			// not (T){0}. Must check before isNilableValueType (which returns true for Union).
			if (unwrapRefNullUnion(node.nodeType) !== null) {
				ctx.results.push(cNullLiteral());
				return;
			}
			if (isNilableValueType(node.nodeType)) {
				const cType = getTypeDesc(g, node.nodeType);
				ctx.results.push(`(${cType}){0}`);
				return;
			}
		}
		ctx.results.push(cNullLiteral());
		return;
	}
	if (kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		// DRC lifecycle hook reference (TypeInfo literal's destroyFn/traceFn fields).
		// When the defining module's TypeInfo references hooks that live in another
		// TU (consumer claimed hook ownership first via split-ownership design),
		// emit extern forward prototypes so the linker resolves them.
		// Filter by resolvedSym===null to skip enum members like `TokenKind_Eq`
		// that happen to match the "Eq" suffix.
		if (node.resolvedSym === null && isDrcLifecycleName(d.name)) {
			ensureDrcProto(g, d.name);
		}
		// Built-in numeric constants → C99 macros
		if (d.name === "NaN") { ctx.results.push("NAN"); return; }
		if (d.name === "Infinity") { ctx.results.push("INFINITY"); return; }
		// MetaScript has no undefined — emit as NULL or {0} for value types
		if (d.name === "undefined") {
			if (node.nodeType !== null && isNilableValueType(node.nodeType)) {
				const cType = getTypeDesc(g, node.nodeType);
				ctx.results.push(`(${cType}){0}`);
				return;
			}
			ctx.results.push(cNullLiteral());
			return;
		}
		// Auto-declare DRC sink temps on first use (zero-init for goto safety)
		if (d.name.startsWith("$sink_") && p !== null) {
			let alreadySeen = false;
			for (const s of p.seenSinks) { if (s === d.name) alreadySeen = true; }
			if (!alreadySeen) {
				p.seenSinks.push(d.name);
				const cType = node.nodeType !== null ? getTypeDesc(g, node.nodeType) : "void*";
				emitProcLocalsLine(p, `  ${cType} ${safeName(d.name)} = {0};`);
			}
		}
		// Ensure cross-module enum constants are emitted (Reference parity: enum definitions per module)
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.Enum) {
			getTypeDesc(g, node.nodeType);
		}
		// Cross-module global variable: emit extern declaration.
		// isModuleGlobalVar already excludes enum members (SymbolKind.EnumMember).
		const idSym = node.resolvedSym;
		if (isModuleGlobalVar(idSym)
			&& idSym.modulePath !== g.modulePath
			&& node.nodeType !== null) {
			// Use the module-qualified name so the extern matches the defining
			// module's declaration at link time (both sides emit the same C symbol).
			const sName = mangledGlobalName(idSym, d.name);
			if (!nameSetHas(g.declaredGlobals, sName)) {
				const cType = getTypeDesc(g, node.nodeType);
				addLine(sec(g, CSection.GlobalVars), `extern ${cType} ${sName};`);
				nameSetAdd(g.declaredGlobals, sName);
			}
		}
		// Module-qualified name for function references (Standard reference parity)
		// nativeName takes priority — used by extern functions and actor dispatch
		if (idSym !== null && idSym.symbolKind === SymbolKind.Function && idSym.nativeName !== "") {
			ctx.results.push(idSym.nativeName);
		} else if (idSym !== null && idSym.symbolKind === SymbolKind.Function) {
			// Ensure cross-module function has a forward declaration (needed for function
			// pointers in closure literals — direct calls go through ensureCrossModuleProto)
			if (idSym.symbolType !== null && idSym.modulePath !== null && idSym.modulePath !== "" && idSym.modulePath !== g.modulePath) {
				ensureCrossModuleProto(g, mangledFunctionName(idSym, d.name, idSym.overloadIdx), idSym.symbolType, idSym);
			}
			ctx.results.push(mangledFunctionName(idSym, d.name, idSym.overloadIdx));
		} else {
			// Reference parity (sym.loc.snippet): symbol-based resolution first.
			// localNameMap fallback for DRC cleanup identifiers with noSym (avoids cascade).
			const isIndirect = isIndirectParam(p, d.name) || isIndirectLocal(p, d.name);
			const safe = safeName(d.name);
			let cName = "";
			if (idSym !== null && idSym.nativeName !== "") {
				cName = idSym.nativeName;
			} else if (isModuleGlobalVar(idSym)) {
				// Module-level variable: compute module-qualified C name on demand.
				// Matches what genGlobalVar emits in the defining module and what the
				// cross-module extern block emits. isModuleGlobalVar already excludes
				// enum members (they are SymbolKind.EnumMember, not Variable), so we
				// don't need a nodeType-based guard here.
				cName = mangledGlobalName(idSym, d.name);
			} else {
				const mapped = lookupLocalName(p, safe);
				cName = mapped !== "" ? mapped : safe;
			}
			const loc: CLoc = {
				kind: CLocKind.LocalVar,
				storage: isIndirect ? CStorageLoc.Unknown : CStorageLoc.Stack,
				snippet: cName,
				isIndirect,
				locType: node.nodeType,
			};
			ctx.results.push(rdLoc(loc));
		}
		return;
	}
	if (kind === NodeKind.ArrowFunction) {
		ctx.results.push("0 /* unlowered ArrowFunction */");
		return;
	}
	if (kind === NodeKind.FunctionExpr) {
		ctx.results.push("0 /* unlowered FunctionExpr */");
		return;
	}

	// MoveExpr — passthrough, just redirect to inner node
	if (kind === NodeKind.MoveExpr) {
		const d = node.data as MoveExprData;
		ctx.workStack.push({ node: d.moveArg, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// BinaryExpr — 2 children
	if (kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		ctx.workStack.push({ node, phase: 1, childCount: 2, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.right, phase: 0, childCount: 0, tag: 0 });
		ctx.workStack.push({ node: d.left, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// UnaryExpr — 1 child
	if (kind === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.operand, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// UpdateExpr — 1 child
	if (kind === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.updateArg, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// MemberExpr — 1 child (object)
	// Note: Enum member access (Color.Red) is rewritten to Identifier("Color_Red")
	// by the checker (checkMemberExpr), so MemberExpr with enum objects never reaches codegen.
	if (kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.object, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// ArrayAccess — 2 children
	if (kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		ctx.workStack.push({ node, phase: 1, childCount: 2, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.index, phase: 0, childCount: 0, tag: 0 });
		ctx.workStack.push({ node: d.array, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// ConditionalExpr — 3 children
	if (kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		ctx.workStack.push({ node, phase: 1, childCount: 3, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.ternaryAlternate, phase: 0, childCount: 0, tag: 0 });
		ctx.workStack.push({ node: d.ternaryConsequent, phase: 0, childCount: 0, tag: 0 });
		ctx.workStack.push({ node: d.ternaryCondition, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// TypeAssertion — 1 child
	if (kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		// Elide `x as unknown as T` chain when typeof(x) === T (no-op in monomorphized generics).
		if (d.asExpr !== null && d.asExpr.kind === NodeKind.TypeAssertion && node.nodeType !== null) {
			const inner = d.asExpr.data as TypeAssertionData;
			if (inner.asExpr !== null) {
				// Use resolvedSym's type if nodeType not stamped (common for parameters)
				let innerType = inner.asExpr.nodeType;
				if (innerType === null && inner.asExpr.resolvedSym !== null) {
					innerType = inner.asExpr.resolvedSym.symbolType;
				}
				const srcDesc = innerType !== null ? getTypeDesc(g, innerType) : "";
				const tgtDesc = getTypeDesc(g, node.nodeType);
				if (srcDesc !== "" && srcDesc === tgtDesc) {
					ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
					ctx.workStack.push({ node: inner.asExpr, phase: 0, childCount: 0, tag: 0 });
					return;
				}
			}
		}
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.asExpr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// SpreadExpr — 1 child
	if (kind === NodeKind.SpreadExpr) {
		const d = node.data as SpreadExprData;
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.spreadArg, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// HiddenDeref — 1 child
	if (kind === NodeKind.HiddenDeref) {
		const d = node.data as ExprStmtData;
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.expr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// HiddenAddr — 1 child
	if (kind === NodeKind.HiddenAddr) {
		const d = node.data as ExprStmtData;
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.expr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// HiddenStdConv / HiddenSubConv — 1 child
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const d = node.data as HiddenStdConvData;
		ctx.workStack.push({ node, phase: 1, childCount: 1, tag: TAG_DEFAULT });
		ctx.workStack.push({ node: d.convExpr, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// ArrayLiteral — keep recursive (side effects: getTemp, emitStmtsLine)
	if (kind === NodeKind.ArrayLiteral) {
		ctx.results.push(genArrayLiteral(g, p, node));
		return;
	}

	// CallExpr — dispatch by call type
	if (kind === NodeKind.CallExpr) {
		discoverCallExpr(g, p, node, ctx);
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
		ctx.workStack.push({ node, phase: 1, childCount: n, tag: TAG_DEFAULT });
		// Push children in reverse order
		let i = n - 1;
		while (i >= 0) {
			ctx.workStack.push({ node: d.properties[i], phase: 0, childCount: 0, tag: 0 });
			i -= 1;
		}
		return;
	}

	// NewExpr — constructor call or inline allocation
	if (kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		// Constructor check (reference parity: sfConstructor flag on symbol).
		// If the class has HasConstructor flag, call ClassName_new(args).
		// Works cross-module via ExportedSymInfo propagation.
		if (d.newCallee.resolvedSym !== null && hasFlag(d.newCallee.resolvedSym, SymbolFlag.HasConstructor)) {
			const newType = node.nodeType;
			// Unwrap Ref → inner struct to get the monomorphized C type name
			let cName = "";
			if (newType !== null && newType.kind === TypeKind.Ref && newType.typeReturn !== null) {
				cName = getTypeDesc(g, newType.typeReturn);
			} else if (newType !== null) {
				cName = getTypeDesc(g, newType);
			} else {
				cName = genExpr(g, p, d.newCallee);
			}
			ensureTypeInfoDef(g, cName);
			const ctorName = cName + "_new";
			let argList = "";
			let ai = 0;
			while (ai < d.newArguments.length) {
				if (ai > 0) argList = argList + ", ";
				argList = argList + genExpr(g, p, d.newArguments[ai]);
				ai += 1;
			}
			ctx.results.push(d.newArguments.length === 0 ? `${ctorName}()` : `${ctorName}(${argList})`);
			return;
		}
		// Value-type new: struct/GenericInstance types → zero-initialized struct
		if (node.nodeType !== null && (node.nodeType.kind === TypeKind.Struct || node.nodeType.kind === TypeKind.GenericInstance) && d.newArguments.length === 0) {
			const cType = getTypeDesc(g, node.nodeType);
			ctx.results.push(`(${cType}){0}`);
			return;
		}
		// Ref-type new: Ref<GenericInstance> → heap-allocate with monomorphized name
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.Ref && node.nodeType.typeReturn !== null) {
			const innerType = node.nodeType.typeReturn;
			const cType = getTypeDesc(g, innerType);
			ensureTypeInfoDef(g, cType);
			if (d.newArguments.length === 0) {
				// Check if any instance fields have initializers
				if (hasInstanceFieldDefaults(node.nodeType)) {
					g.labels += 1;
					const tmp0 = `_new${g.labels}_`;
					emitProcLocalsLine(p, `${cType}* ${tmp0};`);
					emitStmtsLine(p, `${tmp0} = ${genAllocTyped(g, cType)};`);
					emitInstanceFieldDefaults(g, p, tmp0, node.nodeType, 0);
					ctx.results.push(tmp0);
				} else {
					ctx.results.push(`${genAllocTyped(g, cType)}`);
				}
			} else {
				g.labels += 1;
				const tmp = `_new${g.labels}_`;
				emitProcLocalsLine(p, `${cType}* ${tmp};`);
				emitStmtsLine(p, `${tmp} = ${genAllocTyped(g, cType)};`);
				const fieldNames = (innerType.typeNames !== null) ? innerType.typeNames : null as unknown as string[];
				let fi = 0;
				while (fi < d.newArguments.length) {
					const fieldVal = genExpr(g, p, d.newArguments[fi]);
					const fieldName = (fieldNames !== null && fi < fieldNames.length) ? mangleFieldName(fieldNames[fi]) : ("_f" + fi);
					emitStmtsLine(p, `${tmp}->${fieldName} = ${fieldVal};`);
					fi += 1;
				}
				// Apply instance field initializers for fields not covered by constructor args
				emitInstanceFieldDefaults(g, p, tmp, node.nodeType, d.newArguments.length);
				ctx.results.push(tmp);
			}
			return;
		}
		// TypeReference eliminated — all types resolved before codegen
		// new Array(N) with typed element type → allocate array with N zero-initialized elements
		if (node.nodeType !== null && node.nodeType.kind === TypeKind.Array) {
			const arrType = getTypeDesc(g, node.nodeType);
			if (d.newArguments.length === 1) {
				const sizeExpr = genExpr(g, p, d.newArguments[0]);
				// Allocate array with N slots: { .len = N, .p = calloc(sizeof(Content) + N * sizeof(elem)) }
				const elemType = node.nodeType.typeReturn !== null ? getTypeDesc(g, node.nodeType.typeReturn) : "void*";
				const contentType = getArrayContentType(arrType);
				const tmp = getTemp(p, arrType);
				emitStmtsLine(p, `${tmp.snippet}.len = ${sizeExpr};`);
				emitStmtsLine(p, `${tmp.snippet}.p = (${contentType}*)calloc(1, sizeof(${contentType}) + ${sizeExpr} * sizeof(${elemType}));`);
				emitStmtsLine(p, `${tmp.snippet}.p->cap = ${sizeExpr};`);
				ctx.results.push(tmp.snippet);
			} else {
				ctx.results.push(`(${arrType}){0}`);
			}
			return;
		}
		const calleeName = genExpr(g, p, d.newCallee);
		// Ensure cross-module typeInfo is declared
		ensureTypeInfo(g, calleeName);
		ensureForwardDecl(g, calleeName);
		// Constructor check already handled at top of NewExpr handler
		if (d.newArguments.length === 0) {
			// No-arg new without constructor: allocate with zero-init
			ctx.results.push(`${genAllocTyped(g, calleeName)}`);
		} else {
			// Positional args → field-by-field assignment using type info
			g.labels += 1;
			const tmp = `_new${g.labels}_`;
			emitProcLocalsLine(p, `${calleeName}* ${tmp};`);
			// Get field names from the class type (Ref → unwrap to Struct → typeNames)
			const classType = node.nodeType;
			const innerType = (classType !== null && (classType.kind === TypeKind.Ref || classType.kind === TypeKind.Ptr)) ? classType.typeReturn : classType;
			const fieldNames = (innerType !== null && innerType.typeNames !== null) ? innerType.typeNames : null as unknown as string[];
			// Positional args cover EVERY declared field → the loop below writes each
			// explicitly, so Uninit is safe (subject to the no-inheritance guard in pickAllocExpr).
			const argsCover = fieldNames !== null && d.newArguments.length === fieldNames.length;
			emitStmtsLine(p, `${tmp} = ${pickAllocExpr(g, calleeName, innerType, argsCover)};`);
			let fi = 0;
			while (fi < d.newArguments.length) {
				const fieldVal = genExpr(g, p, d.newArguments[fi]);
				const fieldName = (fieldNames !== null && fi < fieldNames.length) ? mangleFieldName(fieldNames[fi]) : ("_f" + fi);
				emitStmtsLine(p, `(*${tmp}).${fieldName} = ${fieldVal};`);
				fi += 1;
			}
			ctx.results.push(tmp);
		}
		return;
	}

	// Fallback
	ctx.results.push(`/* unsupported expression: kind=${kind.toString()} */`);
}

// ===== Discover CallExpr — split by call type =====

function discoverCallExpr(g: CGen, p: CProc, node: Node, ctx: ExprEvalCtx): void {
	const cd = node.data as CallExprData;
	const sym = node.resolvedSym;

	// extern from "c_name" — useHeader propagates #include to consuming module.
	// Runtime externs (no headerPath) already have headers always included (system.h, core/*.h).
	// User externs (with headerPath) get their @include propagated to this module.
	//
	// IMPORTANT: nativeName is overloaded — it's the FFI symbol for extern functions
	// AND the mangled C local name for ordinary variables (set in statements.ms when
	// hoisting decls). Without the SymbolKind guard, a stored closure call like
	// `const f: (n) => N = arrow; f(10)` would be miscompiled as a native FFI call,
	// emitting `f_1_(10)` instead of dispatching through genClosureCall.
	if (sym !== null && sym.nativeName !== ""
		&& sym.symbolKind !== SymbolKind.Variable
		&& sym.symbolKind !== SymbolKind.Parameter
		&& sym.symbolKind !== SymbolKind.Property) {
		useHeader(g, sym);
		ctx.results.push(emitNativeCall(g, p, sym.nativeName, cd.arguments, sym));
		return;
	}

	// Overloaded call — args only, name resolved during Emit
	if (sym !== null && sym.overloads !== null && sym.overloads.length > 0) {
		const n = cd.arguments.length;
		ctx.workStack.push({ node, phase: 1, childCount: n, tag: TAG_CALL_OVERLOAD });
		let i = n - 1;
		while (i >= 0) {
			ctx.workStack.push({ node: cd.arguments[i], phase: 0, childCount: 0, tag: 0 });
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
		ctx.workStack.push({ node, phase: 1, childCount: n, tag: TAG_CALL_CLOSURE });
		let i = cd.arguments.length - 1;
		while (i >= 0) {
			ctx.workStack.push({ node: cd.arguments[i], phase: 0, childCount: 0, tag: 0 });
			i -= 1;
		}
		ctx.workStack.push({ node: cd.callee, phase: 0, childCount: 0, tag: 0 });
		return;
	}

	// TAG_CALL_DIRECT: callee + args
	const n = 1 + cd.arguments.length;
	ctx.workStack.push({ node, phase: 1, childCount: n, tag: TAG_CALL_DIRECT });
	let i = cd.arguments.length - 1;
	while (i >= 0) {
		ctx.workStack.push({ node: cd.arguments[i], phase: 0, childCount: 0, tag: 0 });
		i -= 1;
	}
	ctx.workStack.push({ node: cd.callee, phase: 0, childCount: 0, tag: 0 });
}

// ===== Emit phase: combine child results =====

function emitExpr(g: CGen, p: CProc, item: ExprStackItem, ctx: ExprEvalCtx): void {
	const node = item.node;
	const kind = node.kind;
	const cc = item.childCount;
	const tag = item.tag;

	// BinaryExpr
	if (kind === NodeKind.BinaryExpr) {
		const left = peekResult(ctx, cc, 0);
		const right = peekResult(ctx, cc, 1);
		truncResults(ctx, cc);
		const d = node.data as BinaryExprData;
		let finalRight = right;
		if (d.operator === "=" && d.left.nodeType !== null && d.right.nodeType !== null
				&& d.left.kind !== NodeKind.MemberExpr && d.left.kind !== NodeKind.ArrayAccess) {
			// For assignment LHS, prefer the variable's declared type over narrowed nodeType.
			// Parity: genAsgn uses the declared type (symbol type, never narrowed).
			// Our checker stores narrowed types on nodeType, so we read resolvedSym.symbolType.
			// Skip for MemberExpr/ArrayAccess — C knows the struct field type; our nodeType
			// may be wrong (e.g. msClosure instead of the actual field type).
			let leftType = d.left.nodeType;
			if (d.left.resolvedSym !== null && d.left.resolvedSym.symbolType !== null) {
				leftType = d.left.resolvedSym.symbolType;
			}
			// Unwrap Var<T> (out params) — assignment targets the inner value, not the pointer
			if (leftType !== null && leftType.kind === TypeKind.Var && leftType.typeReturn !== null) {
				leftType = leftType.typeReturn;
			}
			const leftCType = getTypeDesc(g, leftType);
			const rightCType = getTypeDesc(g, d.right.nodeType);
			if (leftCType !== rightCType && leftCType !== "void*" && rightCType !== "void") {
				const destIsPtr = leftCType.indexOf("*") >= 0;
				const srcIsPtr = rightCType.indexOf("*") >= 0;
				if (destIsPtr === srcIsPtr) {
					finalRight = `((${leftCType})(${right}))`;
				}
			}
		}
		// Null assignment to value type: x = MS_NIL → zero-init.
		// Structs/arrays: memset(&x, 0, sizeof(Type)).
		// Numerics: x = 0 (MS_NIL is void*, incompatible with int/float in C).
		if (d.operator === "=" && (finalRight === "MS_NIL" || finalRight === "NULL" || finalRight === "((void*)0)")) {
			const lt = d.left.nodeType;
			if (lt !== null && isNilableValueType(lt)) {
				const cType = getTypeDesc(g, lt);
				ctx.results.push(`memset(&(${left}), 0, sizeof(${cType}))`);
				return;
			}
			if (lt !== null && (isIntegerType(lt) || isFloatType(lt))) {
				ctx.results.push(`(${left} = 0)`);
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
				ctx.results.push(`fmod(${left}, ${finalRight})`);
				return;
			}
		}
		const cOp = mapBinaryOp(d.operator);
		ctx.results.push(`(${left} ${cOp} ${finalRight})`);
		return;
	}

	// UnaryExpr
	if (kind === NodeKind.UnaryExpr) {
		const operand = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		const d = node.data as UnaryExprData;
		ctx.results.push(`(${d.unaryOp}${operand})`);
		return;
	}

	// UpdateExpr
	if (kind === NodeKind.UpdateExpr) {
		const operand = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		const d = node.data as UpdateExprData;
		if (d.isPrefix) {
			ctx.results.push(`(${d.updateOp}${operand})`);
		} else {
			ctx.results.push(`(${operand}${d.updateOp})`);
		}
		return;
	}

	// MemberExpr
	if (kind === NodeKind.MemberExpr) {
		let obj = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		const d = node.data as MemberExprData;

		// Module namespace access: ns.X → emit the resolved symbol's mangled name
		if (d.object.resolvedSym !== null && d.object.resolvedSym.symbolKind === SymbolKind.Module) {
			const nsSym = node.resolvedSym;
			if (nsSym !== null && nsSym.symbolKind === SymbolKind.Function) {
				const fnName = mangledFunctionName(nsSym, d.property, nsSym.overloadIdx);
				ensureCrossModuleProto(g, fnName, nsSym.symbolType, nsSym);
				ctx.results.push(fnName);
			} else if (nsSym !== null) {
				// Constants/variables: module-qualified name so the extern matches
				// the defining module's declaration. Property name is the original
				// identifier post-alias-unwrap (handled inside mangledGlobalName).
				const sName = mangledGlobalName(nsSym, d.property);
				if (node.nodeType !== null && !nameSetHas(g.declaredGlobals, sName)) {
					const cType = getTypeDesc(g, node.nodeType);
					addLine(sec(g, CSection.GlobalVars), `extern ${cType} ${sName};`);
					nameSetAdd(g.declaredGlobals, sName);
				}
				ctx.results.push(sName);
			} else {
				ctx.results.push(safeName(d.property));
			}
			return;
		}

		// Static property access: emit global variable name (ClassName.prop → ClassName__prop)
		if (node.resolvedSym !== null && hasFlag(node.resolvedSym, SymbolFlag.Static)) {
			ctx.results.push(staticFieldCName(node.resolvedSym.name));
			return;
		}

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
					ctx.results.push(`((${elemTypeDesc})${obj})->${prop}`);
				} else {
					ctx.results.push(`${obj}.${prop}`);
				}
				return;
			}
		}
		// Pre-formatted property (e.g. "p->data" from nativeLower) — emit raw
		if (findChar(d.property, ">") >= 0) {
			ctx.results.push(`${obj}.${d.property}`);
			return;
		}
		// .length/.byteLength → .len for runtime types (arrays, strings, spans)
		// SizedArray: compile-time constant size (no .len field in C struct)
		if (d.property === "length" || d.property === "byteLength") {
			const objType = d.object.nodeType;
			if (objType !== null && objType.kind === TypeKind.SizedArray) {
				ctx.results.push(String(objType.typeFlags));
				return;
			}
			const isRuntimeType = objType !== null && (objType.kind === TypeKind.Array
				|| objType.kind === TypeKind.Span
				|| isStringLike(objType));
			if (isRuntimeType) {
				ctx.results.push(obj + ".len");
				return;
			}
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
		// Discriminated union: tag field → _tag, variant fields → v<N>.field
		// Unwrap Ref<Union> for field access (Ref<Union> is how type alias Ref<Data> resolves)
		let objType = d.object.nodeType !== null ? d.object.nodeType
			: (d.object.resolvedSym !== null ? d.object.resolvedSym.symbolType : null);
		if (objType !== null && objType.kind === TypeKind.Ref && objType.typeReturn !== null) {
			objType = objType.typeReturn;
		}
		if (objType !== null && objType.kind === TypeKind.Union) {
			const acc = objIsPtr ? "->" : ".";
			// Tag field access: s.kind → s._tag
			if (isDiscriminatedUnion(objType) && getDiscriminantName(objType) === d.property) {
				ctx.results.push(`${obj}${acc}_tag`);
				return;
			}
			// Variant field access: s.radius → s.v<N>.radius
			const varIdx = findVariantByFieldName(objType, d.property);
			if (varIdx >= 0) {
				ctx.results.push(`${obj}${acc}v${varIdx}.${field}`);
				return;
			}
		}
		if (objIsPtr) {
			ctx.results.push(`${obj}->${field}`);
		} else {
			ctx.results.push(`${obj}.${field}`);
		}
		return;
	}

	// ArrayAccess — after nativeLower, only untyped/raw accesses reach here
	if (kind === NodeKind.ArrayAccess) {
		const arr = peekResult(ctx, cc, 0);
		const idx = peekResult(ctx, cc, 1);
		truncResults(ctx, cc);
		ctx.results.push(`${arr}[${idx}]`);
		return;
	}

	// ConditionalExpr
	if (kind === NodeKind.ConditionalExpr) {
		const cond = peekResult(ctx, cc, 0);
		const cons = peekResult(ctx, cc, 1);
		const alt = peekResult(ctx, cc, 2);
		truncResults(ctx, cc);
		ctx.results.push(`(${cond} ? ${cons} : ${alt})`);
		return;
	}

	// TypeAssertion
	if (kind === NodeKind.TypeAssertion) {
		const expr = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		const d = node.data as TypeAssertionData;

		// Identity cast — src and target have the same C type. Fires at the top
		// so it short-circuits every downstream case (Union narrow, Union wrap,
		// nilable reinterpret, fallback cast). Common after monomorphization and
		// whenever the checker propagates the target type into the inner
		// expression (e.g., ObjectLiteral under `{...} as Union` already emits
		// the outer Union via its own self-wrap path — see ~line 1574).
		// Reference parity: Nim's ccgexprs.nim:genConv does the same via
		// `ignoreConv(e) → expr(p, e[1], d)` before calling genSomeCast.
		const srcType = (d.asExpr !== null) ? d.asExpr.nodeType : null;
		if (srcType !== null && node.nodeType !== null) {
			if (getTypeDesc(g, srcType) === getTypeDesc(g, node.nodeType)) {
				ctx.results.push(expr);
				return;
			}
		}

		// Union handling — two directions:
		// 1. Narrowing: `unionExpr as { field: T }` → `(expr).vN` (access variant)
		// 2. Construction: `{ field: val } as UnionType` → `(Union){ .vN = *(Union_vN*)&expr }`
		//    (reinterpret needed for `{...} as unknown as Union` escape-hatch where
		//    src's C type is anonymous struct, not the named variant struct).

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
				ctx.results.push(`(${expr}).v${varIdx}`);
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
				varIdx = findUnionVariant(unionType, srcType.typeNames, srcType.typeChildren !== null ? srcType.typeChildren : []);
			}
			if (varIdx < 0 && d.asExpr !== null && d.asExpr.kind === NodeKind.ObjectLiteral) {
				const litData = d.asExpr.data as ObjectLiteralData;
				if (litData.keys !== null && litData.keys.length > 0) {
					const keyArr: string[] = [];
					const typeArr: Type[] = [];
					for (let ki = 0; ki < litData.keys.length; ki += 1) {
						keyArr.push(litData.keys[ki]);
						if (ki < litData.properties.length && litData.properties[ki] !== null && litData.properties[ki].nodeType !== null) {
							typeArr.push(litData.properties[ki].nodeType);
						}
					}
					varIdx = findUnionVariant(unionType, keyArr, typeArr);
				}
			}
			if (varIdx >= 0) {
				const varName = `${unionName}_v${varIdx}`;
				// Pointer-based reinterpret: `{ ... } as unknown as Union` (the TS
				// escape-hatch pattern) doesn't propagate target type into the
				// ObjectLiteral, so `expr`'s C type may be an anonymous struct
				// with variant-compatible layout but different C type name. Direct
				// `.vN = expr` would fail C's type check. Reinterpret reads the
				// bytes. Safe here because Case 0 above already handled the
				// same-outer-Union case — srcType here is never Union.
				ctx.results.push(`(${unionName}){ ._tag = ${varIdx}, .v${varIdx} = *(${varName}*)&(${expr}) }`);
				return;
			}
			// Empty object literal (e.g., {} as DocData for Nil/HardLine variants)
			if (d.asExpr !== null && d.asExpr.kind === NodeKind.ObjectLiteral) {
				ctx.results.push(`(${unionName}){ ._tag = -1 }`);
				return;
			}
		}

		// Standard reference implementation: generate typed function pointer cast
		// from nodeType (the callee's Function type). Codegen-only concern.
		// (Identity short-circuit already fired at top of TypeAssertion.)
		let targetType = "";
		if (node.nodeType !== null) {
			targetType = getTypeDesc(g, node.nodeType);
		} else {
			targetType = mangle(d.asType);
		}
		// Value types (structs) can't be directly C-cast. Use pointer reinterpret.
		if (node.nodeType !== null && isNilableValueType(node.nodeType)
			&& d.asExpr !== null && d.asExpr.nodeType !== null && isNilableValueType(d.asExpr.nodeType)) {
			ctx.results.push(`(*(${targetType}*)&(${expr}))`);
			return;
		}
		ctx.results.push(`((${targetType})${expr})`);
		return;
	}

	// SpreadExpr
	if (kind === NodeKind.SpreadExpr) {
		const inner = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		ctx.results.push("/* spread */ " + inner);
		return;
	}

	// HiddenDeref
	if (kind === NodeKind.HiddenDeref) {
		const inner = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		// Ref array access returns void* — cast to typed pointer before deref
		// Reference parity: explicit dereference of a typed location
		const hd = node.data as ExprStmtData;
		if (isRefArrayAccessCall(hd.expr) && hd.expr.nodeType !== null) {
			const elemDesc = getTypeDesc(g, hd.expr.nodeType);
			if (elemDesc !== "void*" && elemDesc !== "void") {
				if (isPointerType(hd.expr.nodeType)) {
					// Ref element: cast void* to typed ptr, deref to struct value
					ctx.results.push(`(*(${elemDesc})${inner})`);
				} else {
					// Value struct element: macro returns struct value, no deref needed
					ctx.results.push(inner);
				}
				return;
			}
		}
		ctx.results.push(`(*${inner})`);
		return;
	}

	// HiddenAddr — Reference parity (standard address generation)
	// Reference: if indirect location, return raw snippet (already a pointer); else &(snippet)
	if (kind === NodeKind.HiddenAddr) {
		const inner = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		const d = node.data as ExprStmtData;
		if (d.expr.kind === NodeKind.Identifier && isIndirectParam(p, (d.expr.data as IdentifierData).name)) {
			// Indirect param: already a pointer — reference pattern returns raw snippet
			ctx.results.push(safeName((d.expr.data as IdentifierData).name));
		} else {
			ctx.results.push(safeAddrOf(g, p, inner, d.expr, node.nodeType));
		}
		return;
	}

	// HiddenStdConv / HiddenSubConv
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) {
		const inner = peekResult(ctx, cc, 0);
		truncResults(ctx, cc);
		const d = node.data as HiddenStdConvData;
		const targetC = getTypeDesc(g, d.convType);
		// Zero-copy string ↔ uint8[] bridge: pointer cast (same memory layout)
		if ((node.flags & NodeFlag.Cursor) !== 0) {
			ctx.results.push(`*((${targetC}*)&(${inner}))`);
			return;
		}
		ctx.results.push(`((${targetC})(${inner}))`);
		return;
	}

	// CallExpr
	if (kind === NodeKind.CallExpr) {
		emitCallExpr(g, p, item, ctx);
		return;
	}

	// ObjectLiteral
	if (kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		if ((node.flags & NodeFlag.Closure) !== 0) {
			// Closure literal: (msClosure){ .fn = ..., .env = ... }
			// Standard reference pattern: env is heap-allocated via msAllocTyped, fields initialized,
			// then closure pair references the pointer.
			const fnExpr = peekResult(ctx, cc, 0);
			const envExpr = peekResult(ctx, cc, 1);
			truncResults(ctx, cc);
			if (envExpr === "MS_NIL" || envExpr === "NULL") {
				ctx.results.push(`(msClosure){ .fn = (void*)${fnExpr}, .env = NULL }`);
			} else {
				// Check if env is a pre-allocated named variable (lambda lifting env rewrite)
				// vs inline ObjectLiteral (original pattern needing heap allocation)
				const envNode = d.properties[1];
				if (envNode !== null && envNode.kind === NodeKind.Identifier) {
					// Pre-allocated env: already a heap pointer, use directly
					ctx.results.push(`(msClosure){ .fn = (void*)${fnExpr}, .env = (void*)${envExpr} }`);
				} else {
					// Inline env: heap-allocate, init fields, use pointer.
					// The `*envTemp = envExpr` below is a full struct copy that overwrites
					// every byte of the payload (envExpr is always a fully-initialised
					// stack struct from the ObjectLiteral sibling path). Uninit is safe.
					const envTypeName = (envNode !== null && envNode.nodeType !== null) ? getTypeDesc(g, envNode.nodeType) : "void";
					g.labels += 1;
					const envTemp = `_env${g.labels}_`;
					emitProcLocalsLine(p, `${envTypeName}* ${envTemp};`);
					emitStmtsLine(p, `${envTemp} = (${envTypeName}*)msAllocTypedUninit(sizeof(${envTypeName}), NULL);`);
					emitStmtsLine(p, `*${envTemp} = ${envExpr};`);
					ctx.results.push(`(msClosure){ .fn = (void*)${fnExpr}, .env = (void*)${envTemp} }`);
				}
			}
		} else {
			// Reference-aligned: hoist struct literal to temp variable + field-by-field assignment.
			// Reference implementation (object construction): generate temporary → assign fields → use temporary.
			// Never emits inline compound literals — works with C89+ and avoids &({...}) issues.
			let cType = "";
			let isClassObj = false;
			let unionWrapName = "";
			let unionWrapIdx = -1;
			let unionDiscKeyIdx = -1;
			let isRefUnion = false;
			if (node.nodeType !== null) {
				// Unwrap Ref<Union> for discriminated union construction
				let litType = node.nodeType;
				// Union(Ref<T>, Null) — collapse to bare Ref<T> so the rest of the
				// dispatch picks the Ref/heap-alloc path. The source-level union
				// stays on node.nodeType for narrowing fidelity; we only override
				// the local litType used for layout decisions here.
				const refFromUnion = unwrapRefNullUnion(litType);
				if (refFromUnion !== null) {
					litType = refFromUnion;
				}
				if (litType.kind === TypeKind.Ref && litType.typeReturn !== null && litType.typeReturn.kind === TypeKind.Union) {
					litType = litType.typeReturn;
					isRefUnion = true;
				}
				if (litType.kind === TypeKind.Union && d.keys.length > 0) {
					const unionName = getTypeDesc(g, litType);
					// Discriminated union: use discriminant key to find variant
					const discName = isDiscriminatedUnion(litType) ? getDiscriminantName(litType) : "";
					let discKeyIdx = -1;
					if (discName !== "") {
						let ki = 0;
						while (ki < d.keys.length) {
							if (d.keys[ki] === discName) { discKeyIdx = ki; ki = d.keys.length; }
							ki = ki + 1;
						}
					}
					unionDiscKeyIdx = discKeyIdx;
					if (discKeyIdx >= 0) {
						// Discriminated: resolve variant from discriminant value
						const discValNode = d.properties[discKeyIdx];
						let discValStr = "";
						if (discValNode !== null && discValNode.kind === NodeKind.MemberExpr) {
							const md = discValNode.data as MemberExprData;
							if (md.object !== null && md.object.kind === NodeKind.Identifier) {
								discValStr = (md.object.data as IdentifierData).name + "." + md.property;
							}
						} else if (discValNode !== null && discValNode.kind === NodeKind.Identifier) {
							// Checker rewrites Enum.Member → Enum_Member identifier
							const idName = (discValNode.data as IdentifierData).name;
							// Convert Enum_Member back to Enum.Member for variant lookup
							const usIdx = idName.indexOf("_");
							if (usIdx > 0) {
								discValStr = idName.slice(0, usIdx) + "." + idName.slice(usIdx + 1, idName.length);
							} else {
								discValStr = idName;
							}
						}
						const varIdx = findVariantByDiscriminant(litType, discValStr);
						if (varIdx >= 0) {
							cType = `${unionName}_v${varIdx}`;
							unionWrapName = unionName;
							unionWrapIdx = varIdx;
						}
					} else {
						// Undiscriminated: use checker-stamped variant index (high 16 bits of flags).
						// Reference parity: sem stamps resolved variant, codegen reads directly.
						const stamped = ((node.flags >> 16) & 65535) as int32;
						let varIdx = stamped > 0 ? stamped - 1 : -1;
						// Fallback: re-match by field names + types (for nodes not checked, e.g. transforms)
						if (varIdx < 0 && d.keys.length > 0) {
							const keyArr: string[] = [];
							const typeArr: Type[] = [];
							for (let ki = 0; ki < d.keys.length; ki += 1) {
								keyArr.push(d.keys[ki]);
								if (ki < d.properties.length && d.properties[ki] !== null && d.properties[ki].nodeType !== null) {
									typeArr.push(d.properties[ki].nodeType);
								}
							}
							varIdx = findUnionVariant(node.nodeType, keyArr, typeArr);
							// Last resort: name-only if type kinds mismatch (constant folding, etc.)
							if (varIdx < 0 && typeArr.length > 0) {
								varIdx = findUnionVariant(node.nodeType, keyArr, []);
							}
						}
						if (varIdx >= 0) {
							cType = `${unionName}_v${varIdx}`;
							unionWrapName = unionName;
							unionWrapIdx = varIdx;
						}
					}
				} else if (litType.kind === TypeKind.Ref && litType.typeReturn !== null) {
					// Class/interface type: ObjectLiteral constructs inner struct, heap-allocated.
					// litType is the unwrapped form — bare Ref<T> here, even when node.nodeType
					// is Union(Ref<T>, Null). Source-level union stays on node.nodeType.
					cType = getTypeDesc(g, litType.typeReturn);
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
				const tmpName = `_lit${p.labels}_`;
				const access = isClassObj ? "->" : ".";
				if (isClassObj) {
					// Class: heap-allocate (Reference parity: managed object construction).
					// msAllocTyped now zero-fills payload, so the redundant memset is dropped.
					// Upgrade to msAllocTypedUninit when the literal writes every declared
					// field (Nim nimNewObjUninit parity). The NullLiteral-skip logic below
					// relies on the field already being zero, so we must also require that
					// no property in this literal is a bare NullLiteral.
					ensureTypeInfoDef(g, cType);
					emitProcLocalsLine(p, `${cType}* ${tmpName};`);
					const innerStruct = (node.nodeType !== null && node.nodeType.kind === TypeKind.Ref) ? node.nodeType.typeReturn : node.nodeType;
					const fieldNames = (innerStruct !== null && innerStruct.typeNames !== null) ? innerStruct.typeNames : null as unknown as string[];
					// Bare-NullLiteral keys are skipped by the assignment loop below and
					// rely on the field being pre-zeroed; that's incompatible with Uninit.
					let hasNullProp = false;
					for (const prop of d.properties) {
						if (prop.kind === NodeKind.NullLiteral) { hasNullProp = true; break; }
					}
					const keysCover = fieldNames !== null && d.keys.length === fieldNames.length && !hasNullProp;
					emitStmtsLine(p, `${tmpName} = ${pickAllocExpr(g, cType, innerStruct, keysCover)};`);
				} else {
					// Value type: stack-allocate (no slab zero available — memset explicitly)
					emitProcLocalsLine(p, `${cType} ${tmpName};`);
					emitStmtsLine(p, `memset(&${tmpName}, 0, sizeof(${cType}));`);
				}
				let i = 0;
				while (i < d.keys.length) {
					const val = peekResult(ctx, cc, i);
					// Skip discriminant key — handled by _tag in union wrap
					if (i === unionDiscKeyIdx) { i += 1; continue; }
					// Skip NullLiteral fields — memset already zeroed them.
					// This avoids void* → value-type errors for self-referential pointer fields
					// where the C field is T* but the MS type is T (e.g. Type.typeReturn).
					if (d.properties[i].kind !== NodeKind.NullLiteral) {
						emitStmtsLine(p, `${tmpName}${access}${mangleFieldName(d.keys[i])} = ${val};`);
					}
					i += 1;
				}
				truncResults(ctx, cc);
				if (unionWrapIdx >= 0 && isRefUnion) {
					// Ref<Union>: heap-allocate union, assign variant
					p.labels += 1;
					const refTmp = `_ref${p.labels}_`;
					emitProcLocalsLine(p, `${unionWrapName}* ${refTmp};`);
					emitStmtsLine(p, `${refTmp} = (${unionWrapName}*)msAlloc(sizeof(${unionWrapName}));`);
					emitStmtsLine(p, `${refTmp}->_tag = ${unionWrapIdx};`);
					emitStmtsLine(p, `${refTmp}->v${unionWrapIdx} = ${tmpName};`);
					ctx.results.push(refTmp);
				} else if (unionWrapIdx >= 0) {
					// Value union: wrap variant struct in compound literal
					ctx.results.push(`(${unionWrapName}){ ._tag = ${unionWrapIdx}, .v${unionWrapIdx} = ${tmpName} }`);
				} else {
					ctx.results.push(tmpName);
				}
			} else {
				// Reference-aligned fallback: hoist to temp even without type info.
				// Generate anonymous struct type from field names + inferred C types.
				// Reference implementation: object construction always has type info. We approximate by using field values' types.
				p.labels += 1;
				const tmpName = `_lit${p.labels}_`;
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
					structDef = structDef + `${fieldType} ${mangleFieldName(d.keys[i])};`;
					i += 1;
				}
				structDef = structDef + " }";
				emitProcLocalsLine(p, `${structDef} ${tmpName};`);
				emitStmtsLine(p, `memset(&${tmpName}, 0, sizeof(${tmpName}));`);
				i = 0;
				while (i < d.keys.length) {
					const val = peekResult(ctx, cc, i);
					if (d.properties[i].kind !== NodeKind.NullLiteral) {
						emitStmtsLine(p, `${tmpName}.${mangleFieldName(d.keys[i])} = ${val};`);
					}
					i += 1;
				}
				truncResults(ctx, cc);
				ctx.results.push(tmpName);
			}
		}
		return;
	}

	// NewExpr handled entirely in discover phase (inline allocation)

	// Fallback
	truncResults(ctx, cc);
	ctx.results.push(`/* unsupported expression: resolve kind=${kind.toString()} */`);
}

// ===== genClosureCall — Standard reference parity (closure calling convention) =====
// Generates:  (cl.env) ? ((RetType(*)(Params, void*))cl.fn)(args, cl.env)
//                       : ((RetType(*)(Params))cl.fn)(args)
// env is LAST parameter (Standard reference pattern).
// No forward declarations — closure struct is self-contained.

function genClosureCall(g: CGen, p: CProc, callee: string, argsStr: string, calleeType: Type, node: Node, ctx: ExprEvalCtx): void {
	// Reference implementation pattern: extract environment and function pointers from closure pair
	const envExpr = callee + ".env";
	const fnExpr = callee + ".fn";

	// NRVO for closures: pass &dest as first param (our convention; reference uses last param)
	const nrvoRet = getCalleeReturnType(node);
	const nrvoFuncType = getCalleeFuncType(node);
	const nrvoType = (nrvoRet !== null && isNrvoReturnType(nrvoRet, nrvoFuncType)) ? nrvoRet : null;

	if (nrvoType !== null) {
		// NRVO: allocate temp, pass &tmp as first arg, read tmp after call
		const cType = getTypeDesc(g, nrvoType);
		const tmp = getTemp(p, cType);
		const nrvoArg = "&" + tmp.snippet;
		let fullArgs = "";
		if (argsStr !== "") {
			fullArgs = `${nrvoArg}, ${argsStr}`;
		} else {
			fullArgs = nrvoArg;
		}
		// Cast with NRVO-aware signature (void return, ResultType* first param)
		const clFull = genClFullCastNrvo(g, calleeType, cType);
		const clHalf = genClHalfCastNrvo(g, calleeType, cType);
		const callWithEnv = `((${clFull})${fnExpr})(${fullArgs}, ${envExpr})`;
		const callNoEnv = `((${clHalf})${fnExpr})(${fullArgs})`;
		emitStmtsLine(p, `(${envExpr} ? ${callWithEnv} : ${callNoEnv});`);
		ctx.results.push(tmp.snippet);
		return;
	}

	// Non-NRVO: inline expression form
	const clFull = genClFullCast(g, calleeType);
	const clHalf = genClHalfCast(g, calleeType);

	// With env: fn(args..., env) — env LAST
	let callWithEnv = "";
	if (argsStr !== "") {
		callWithEnv = `((${clFull})${fnExpr})(${argsStr}, ${envExpr})`;
	} else {
		callWithEnv = `((${clFull})${fnExpr})(${envExpr})`;
	}

	// Without env: ((cast)fn)(args...)
	let callNoEnv = "";
	if (argsStr !== "") {
		callNoEnv = `((${clHalf})${fnExpr})(${argsStr})`;
	} else {
		callNoEnv = `((${clHalf})${fnExpr})()`;
	}

	// Reference parity: procedure call dispatch
	// Closure calls generate inline if/else dispatch on env != NULL.
	ctx.results.push(`(${envExpr} ? ${callWithEnv} : ${callNoEnv})`);
}

// ===== Emit CallExpr =====

function emitCallExpr(g: CGen, p: CProc, item: ExprStackItem, ctx: ExprEvalCtx): void {
	const node = item.node;
	const cd = node.data as CallExprData;
	const cc = item.childCount;
	const tag = item.tag;
	const sym = node.resolvedSym;

	if (tag === TAG_CALL_OVERLOAD) {
		// Overloaded: all cc children are args (no callee child).
		//
		// cd.resolvedOverloadIdx is the RAW winner slot from check-time
		// overload resolution — slot 0 = primary, slot k = sym.overloads[k-1].
		// The winner may be a body-less signature (OverloadSig flag). In that
		// case we sig→impl redirect HERE (codegen-local concern): find the
		// unique body-bearing sym in the overload set and emit the call
		// against ITS mangled name. Keeping the redirect in codegen lets
		// check-time preserve the winner slot for LSP views (hover, sig
		// help) while still emitting correct C.
		const winnerIdx = cd.resolvedOverloadIdx;
		let winnerSym: Symbol = sym;
		if (winnerIdx > 0 && winnerIdx - 1 < sym.overloads.length) {
			winnerSym = sym.overloads[winnerIdx - 1];
		}
		let emitIdx = winnerIdx;
		let emitSym = winnerSym;
		if (winnerSym !== null && hasFlag(winnerSym, SymbolFlag.OverloadSig)) {
			// Winner is a body-less sig — redirect to the impl.
			if (!hasFlag(sym, SymbolFlag.OverloadSig)) {
				emitSym = sym;
				emitIdx = 0;
			} else {
				let oi: int32 = 0;
				while (oi < sym.overloads.length) {
					const cand = sym.overloads[oi];
					if (cand !== null && !hasFlag(cand, SymbolFlag.OverloadSig)) {
						emitSym = cand;
						emitIdx = oi + 1;
						break;
					}
					oi = oi + 1;
				}
			}
		}
		// ABI shim uses the EMITTED (impl) function type — that's the
		// actual C function signature we're calling into.
		let ovType = emitSym !== null && emitSym.symbolType !== null
			? emitSym.symbolType
			: sym.symbolType;
		const hasOvParams = ovType !== null && ovType.kind === TypeKind.Function && ovType.typeChildren !== null;
		// Resolve nativeName from the EMITTED sym (the impl owns the binding).
		let ovNativeName = "";
		if (emitSym !== null && emitSym.nativeName !== "") {
			ovNativeName = emitSym.nativeName;
		}
		const ovNeedsAddr = hasAddrPrefix(ovNativeName);
		// Build args with pointer/value ABI shim (genArg via shimCallArg)
		let argsStr = "";
		let ai = 0;
		while (ai < cc) {
			if (ai > 0) argsStr = argsStr + ", ";
			let arg = ctx.results[ctx.results.length - cc + ai];
			// & prefix on nativeName: wrap first arg with &(...)
			if (ovNeedsAddr && ai === 0) {
				arg = safeAddrOf(g, p, arg, cd.arguments[ai], null);
			} else if (hasOvParams && ai < ovType.typeChildren.length && ai < cd.arguments.length) {
				const ovMutBits: int32 = sym !== null ? sym.mutatedParams : 0;
				arg = shimCallArg(g, p, arg, ovType.typeChildren[ai], cd.arguments[ai], ovMutBits, ai);
			}
			argsStr = argsStr + arg;
			ai += 1;
		}
		truncResults(ctx, cc);
		if (ovNativeName !== "") {
			ctx.results.push(`${stripAddrPrefix(ovNativeName)}(${argsStr})`);
			return;
		}
		const ovIdx = emitIdx >= 0 ? emitIdx : 0;
		const ovCalleeName = mangledFunctionName(sym, sym.name, ovIdx);
		// On-demand cross-module prototype (reference parity: genProcPrototype)
		ensureCrossModuleProto(g, ovCalleeName, ovType, sym);
		ctx.results.push(`${ovCalleeName}(${argsStr})`);
		return;
	}

	// Direct or closure: first child is callee, rest are args
	const callee = peekResult(ctx, cc, 0);

	// Stack-local array calls (ABI-portable, avoids aarch64-windows-gnu variadic
	// 16-byte struct ABI bug — LLVM #89615):
	//   msStringConcatArr(count, a, b, c)       → msStringConcatArr(arr, count)
	//   msStringArrayFromArr(count, a, b, c)    → msStringArrayFromArr(arr, count)
	//   msStringAppendArr(dest, count, a, b, c) → msStringAppendArr(dest, arr, count)
	// Each variant shares the stack-array fill; differs only in the surrounding
	// call shape.
	if (callee === "msStringConcatArr" || callee === "msStringArrayFromArr") {
		if (cc >= 3) {
			const countStr = peekResult(ctx, cc, 1);
			const tmpName = emitStringArrayLocal(g, p, ctx, cc, 2, "_mscc");
			truncResults(ctx, cc);
			ctx.results.push(`${callee}(${tmpName}, ${countStr})`);
			return;
		}
	} else if (callee === "msStringAppendArr" && cc >= 4) {
		const destStr = peekResult(ctx, cc, 1);
		const countStr = peekResult(ctx, cc, 2);
		const tmpName = emitStringArrayLocal(g, p, ctx, cc, 3, "_msap");
		truncResults(ctx, cc);
		ctx.results.push(`msStringAppendArr(${destStr}, ${tmpName}, ${countStr})`);
		return;
	}

	// C varargs: msNumberArrayFrom(count, (double)(e1), ...) — va_arg reads 8 bytes for double
	const isNumberArrayFrom = callee === "msNumberArrayFrom";
	// Resolve callee's function type for parameter type checking
	const calleeType = sym !== null && sym.symbolType !== null ? sym.symbolType : (cd.callee.nodeType !== null ? cd.callee.nodeType : null);
	const hasParamTypes = calleeType !== null && calleeType.kind === TypeKind.Function && calleeType.typeChildren !== null;
	let argsStr = "";
	let i = 1;
	while (i < cc) {
		if (i > 1) argsStr = argsStr + ", ";
		let arg = peekResult(ctx, cc, i);
		if (isNumberArrayFrom && i > 1) {
			arg = `(double)(${arg})`;
		} else if (hasParamTypes) {
			const argIdx = i - 1;
			if (argIdx < calleeType.typeChildren.length && argIdx < cd.arguments.length) {
				const callMutBits: int32 = sym !== null ? sym.mutatedParams : 0;
				arg = shimCallArg(g, p, arg, calleeType.typeChildren[argIdx], cd.arguments[argIdx], callMutBits, argIdx);
			}
		}
		argsStr = argsStr + arg;
		i += 1;
	}
	truncResults(ctx, cc);

	// ===== Reference parity: closure call (standard reference pattern) =====
	// Closure calls generate inline if/else dispatch on env != NULL.
	// No forward declarations — closure is a self-contained struct value.
	if (tag === TAG_CALL_CLOSURE) {
		genClosureCall(g, p, callee, argsStr, calleeType, node, ctx);
		return;
	}

	// ===== genPrefixCall (TAG_CALL_DIRECT) =====
	// On-demand cross-module prototype (reference parity: genProcPrototype)
	const protoSym = sym !== null ? sym : (cd.callee.resolvedSym !== null ? cd.callee.resolvedSym : null as unknown as Symbol);
	const protoType = protoSym !== null && protoSym.symbolType !== null ? protoSym.symbolType : calleeType;
	ensureCrossModuleProto(g, callee, protoType, protoSym);
	// DRC hooks — emit forward declaration on-demand
	ensureDrcProto(g, callee);

	// msBoxStruct(val) → msBoxStruct(&val, sizeof(TypeName))
	// spawnLower emits this for struct returns. nodeType carries the type.
	if (callee === "msBoxStruct" && node.nodeType !== null) {
		const boxType = getTypeDesc(g, node.nodeType);
		// Explicitly add & — ccgIntroducedPtr won't fire for synthetic calls
		const addrArg = argsStr.length > 0 && argsStr.charAt(0) === "&" ? argsStr : "&(" + argsStr + ")";
		ctx.results.push(`msBoxStruct(${addrArg}, sizeof(${boxType}))`);
		return;
	}

	// msSinkBoxStruct(val) → malloc + memcpy + memset (DRC-aware boxing)
	// spawnLower emits this for struct returns. The boxed value's type is the
	// argument's nodeType (the value being boxed) — the call's own nodeType is
	// void* (heap pointer). Reading T from args[0] keeps `nodeType` = result type
	// throughout, preserving DRC's cross-pass contract.
	// After memcpy, zeros source so DRC destroy is no-op on ref-counted fields.
	if (callee === "msSinkBoxStruct" && cd.arguments.length >= 1 && cd.arguments[0].nodeType !== null) {
		const sinkType = getTypeDesc(g, cd.arguments[0].nodeType);
		const boxTmp = getTemp(p, "void*");
		const addrArg = argsStr.length > 0 && argsStr.charAt(0) === "&" ? argsStr : "&(" + argsStr + ")";
		emitStmtsLine(p, `${boxTmp.snippet} = malloc(sizeof(${sinkType}));`);
		emitStmtsLine(p, `memcpy(${boxTmp.snippet}, ${addrArg}, sizeof(${sinkType}));`);
		// Neutralize source: zero all bytes so DRC destroy sees no refs to release
		emitStmtsLine(p, `memset(${addrArg}, 0, sizeof(${sinkType}));`);
		ctx.results.push(boxTmp.snippet);
		return;
	}

	// msUnboxStruct(ptr) → copy out + free shell (DRC-aware unboxing)
	// WaitFor builtin emits this for struct returns from spawn. nodeType carries the target type.
	if (callee === "msUnboxStruct" && node.nodeType !== null) {
		const unboxType = getTypeDesc(g, node.nodeType);
		const ptrTmp = getTemp(p, "void*");
		const valTmp = getTemp(p, unboxType);
		emitStmtsLine(p, `${ptrTmp.snippet} = ${argsStr};`);
		emitStmtsLine(p, `${valTmp.snippet} = *(${unboxType}*)${ptrTmp.snippet};`);
		emitStmtsLine(p, `free(${ptrTmp.snippet});`);
		ctx.results.push(valTmp.snippet);
		return;
	}

	// msFutureCreateInline() → typed-sized future allocation for inline struct storage.
	// asyncBridge emits this when an async function returns a struct type that would
	// overflow the generic msFutureCreate() 16-byte value slot. The call's own nodeType
	// is Promise<T> (its true result type); T is extracted via awaitedType so DRC's
	// cross-pass contract (`nodeType = result type`) is preserved.
	if (callee === "msFutureCreateInline" && node.nodeType !== null) {
		const innerT = awaitedType(node.nodeType);
		if (innerT !== null) {
			const innerC = getTypeDesc(g, innerT);
			const futStructName = "msFuture_" + mangle(innerC);
			addLine(sec(g, CSection.Types), `#ifndef ${futStructName}_DEFINED`);
			addLine(sec(g, CSection.Types), `#define ${futStructName}_DEFINED`);
			addLine(sec(g, CSection.Types), `MS_FUTURE_STRUCT(${futStructName}, ${innerC});`);
			addLine(sec(g, CSection.Types), `#endif`);
			ctx.results.push(`(${futStructName}*)msAlloc(sizeof(${futStructName}))`);
			return;
		}
	}

	// msSpawnInto(fut, closure, sizeof_T, offsetof_value) → T is read from the first
	// arg's nodeType. Post cleanup: args[0] is the msFutureCreateInline call whose
	// nodeType is Promise<T>, so we extract T via awaitedType. sizeof + offsetof are
	// needed because the worker memcpys into the typed inline value slot, whose offset
	// differs from msFuture_ptr.value on 32-bit WASM due to alignment.
	if (callee === "msSpawnInto" && cd.arguments.length >= 1 && cd.arguments[0].nodeType !== null) {
		const arg0T = cd.arguments[0].nodeType;
		const innerT = awaitedType(arg0T) !== null ? awaitedType(arg0T) : arg0T;
		const innerC = getTypeDesc(g, innerT);
		const futStructName = "msFuture_" + mangle(innerC);
		addLine(sec(g, CSection.Types), `#ifndef ${futStructName}_DEFINED`);
		addLine(sec(g, CSection.Types), `#define ${futStructName}_DEFINED`);
		addLine(sec(g, CSection.Types), `MS_FUTURE_STRUCT(${futStructName}, ${innerC});`);
		addLine(sec(g, CSection.Types), `#endif`);
		ctx.results.push(`msSpawnInto(${argsStr}, sizeof(${innerC}), offsetof(${futStructName}, value))`);
		return;
	}

	// msWaitForStruct(fut) → blocking wait + typed inline read of struct value.
	// Emitted by WaitFor builtin for struct return types. Assumes the source future
	// was allocated via msFutureCreateInline (or asyncBridge for struct returns).
	// Casts to the actual typed future struct (msFuture_<T>) to read .value at the
	// correct offset — msFuture_ptr cast would be wrong on 32-bit (WASM) where
	// double/struct alignment differs from void* alignment.
	if (callee === "msWaitForStruct" && node.nodeType !== null) {
		const structType = getTypeDesc(g, node.nodeType);
		const futStructName = "msFuture_" + mangle(structType);
		// Ensure the typed future struct is defined
		addLine(sec(g, CSection.Types), `#ifndef ${futStructName}_DEFINED`);
		addLine(sec(g, CSection.Types), `#define ${futStructName}_DEFINED`);
		addLine(sec(g, CSection.Types), `MS_FUTURE_STRUCT(${futStructName}, ${structType});`);
		addLine(sec(g, CSection.Types), `#endif`);
		const futTmp = getTemp(p, "void*");
		const valTmp = getTemp(p, structType);
		emitStmtsLine(p, `${futTmp.snippet} = ${argsStr};`);
		emitStmtsLine(p, `msWaitForReady(${futTmp.snippet});`);
		emitStmtsLine(p, `${valTmp.snippet} = ((${futStructName}*)${futTmp.snippet})->value;`);
		ctx.results.push(valTmp.snippet);
		return;
	}

	// Lazy MS_PROMISE_ALL_FOR emission — side-effect only, falls through to normal
	// call emission. When the transform dispatched Promise.all to the typed variant
	// `msPromiseAllFor_msFuture_<T>`, ensure the matching runtime instance is emitted
	// in this translation unit. The #ifndef guard inside emitPromiseAllInstance
	// dedups across repeat calls. The element type T is recovered from the argument's
	// nodeType (`Promise<T>[]`) via its `typeReturn` (the element Promise<T>) and
	// awaitedType.
	if (cd.arguments.length >= 1 && cd.arguments[0].nodeType !== null
		&& callee.startsWith("msPromiseAllFor_msFuture_")) {
		const argArrType = cd.arguments[0].nodeType;
		const elementPromise = argArrType.typeReturn;
		if (elementPromise !== null) {
			const innerT = awaitedType(elementPromise);
			if (innerT !== null) ensurePromiseAllInstance(g, innerT);
		}
	}

	const calleeStr = callee;
	// NRVO: call returns void, result via out-param
	const nrvoRet = getCalleeReturnType(node);
	const nrvoFuncType2 = getCalleeFuncType(node);
	const nrvoType = (nrvoRet !== null && isNrvoReturnType(nrvoRet, nrvoFuncType2)) ? nrvoRet : null;
	if (nrvoType !== null) {
		const cType = getTypeDesc(g, nrvoType);
		const tmp = getTemp(p, cType);
		let nrvoArgs = "&" + tmp.snippet;
		if (argsStr !== "") nrvoArgs = `${nrvoArgs}, ${argsStr}`;
		emitStmtsLine(p, `${calleeStr}(${nrvoArgs});`);
		ctx.results.push(tmp.snippet);
	} else if (argsStr === "") {
		ctx.results.push(calleeStr + "()");
	} else {
		ctx.results.push(`${calleeStr}(${argsStr})`);
	}
}
// ===== genExprAssign — evaluate expression and assign to dest =====
// For statement-level: `dest = expr;`

export function genExprAssign(g: CGen, p: CProc, node: Node, destSnippet: string): void {
	const snippet = genExpr(g, p, node);
	addLine(pStmts(p), `${destSnippet} = ${snippet};`);
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
	if (nativeName.length > 0 && nativeName.charAt(0) === "&") {
		return nativeName.slice(1, nativeName.length);
	}
	return nativeName;
}

function hasAddrPrefix(nativeName: string): boolean {
	return nativeName.length > 0 && nativeName.charAt(0) === "&";
}

function emitNativeCall(g: CGen, p: CProc, nativeName: string, args: Node[], sym: Symbol): string {
	const needsAddr = hasAddrPrefix(nativeName);
	let cName = stripAddrPrefix(nativeName);

	// Array type suffix: ms_array_X → ms_array_X_number/_string/_ref
	if (args.length > 0 && args[0].nodeType !== null) {
		const recvType = args[0].nodeType;
		if (recvType.kind === TypeKind.Array) {
			if (cName.length >= 9 && cName.slice(0, 9) === "ms_array_") {
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

	// Resolve callee function type for out-param ABI shim
	// Extern functions define their own C signatures, so only apply shim for
	// explicit out params (Var<T>), not general ccg-introduced types.
	let fnType: Type = null as unknown as Type;
	if (sym !== null && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Function) {
		fnType = sym.symbolType;
	}
	let paramTypes: Type[] = null as unknown as Type[];
	if (fnType !== null) paramTypes = fnType.typeChildren;

	// Build call with & on first arg if mutating
	if (needsAddr && args.length > 0) {
		const firstArg = genExpr(g, p, args[0]);
		let result = `${cName}(${safeAddrOf(g, p, firstArg, args[0], null)}`;
		let i = 1;
		while (i < args.length) {
			let arg = genExpr(g, p, args[i]);
			if (paramTypes !== null && i < paramTypes.length && paramTypes[i] !== null && paramTypes[i].kind === TypeKind.Var) {
				arg = safeAddrOf(g, p, arg, args[i], paramTypes[i]);
			}
			result = result + `, ${arg}`;
			i = i + 1;
		}
		return result + ")";
	}
	// Apply out-param shim (Var<T> → &arg)
	if (paramTypes !== null) {
		let hasOutParam = false;
		let i = 0;
		while (i < paramTypes.length) {
			if (paramTypes[i] !== null && paramTypes[i].kind === TypeKind.Var) { hasOutParam = true; }
			i += 1;
		}
		if (hasOutParam) {
			let result = cName + "(";
			i = 0;
			while (i < args.length) {
				if (i > 0) result = result + ", ";
				let arg = genExpr(g, p, args[i]);
				if (i < paramTypes.length && paramTypes[i] !== null && paramTypes[i].kind === TypeKind.Var) {
					arg = safeAddrOf(g, p, arg, args[i], paramTypes[i]);
				}
				result = result + arg;
				i += 1;
			}
			return result + ")";
		}
	}
	return `${cName}(${joinArgs(g, p, args)})`;
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
		let result = `(${typeName}){ `;
		let i = 0;
		while (i < d.elements.length) {
			if (i > 0) result = result + ", ";
			result = result + `._${i} = ${genExpr(g, p, d.elements[i])}`;
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
		return `(${arrayTypeName}){0}`;
	}

	// Non-primitive: temp + push pattern
	// (number/string arrays already lowered to msNumberArrayFrom/msStringArrayFromArr CallExpr by nativeLower)
	const tmp = getTemp(p, arrayTypeName);
	const tmpName = tmp.snippet;
	emitStmtsLine(p, `${tmpName} = (${arrayTypeName}){0};`);
	let i = 0;
	while (i < d.elements.length) {
		emitStmtsLine(p, `msGenericArrayPush(&${tmpName}, ${genExpr(g, p, d.elements[i])});`);
		i += 1;
	}
	return tmpName;
}

// ===== Tests =====

import { createCGen, createProc, sec, CSection, isIndirectParam, isIndirectLocal } from "./context";
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
	const p = createProc("test", voidType());
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

test "simple new" { assert exprSnippet("new Foo();") === "(Foo*)msAllocTyped(sizeof(Foo), &FooTypeInfo)"; }

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
		if (result.slice(j, j + 7) === "(a + a)") {
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
		if (result.slice(j, j + 4) === "f(f(") {
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
