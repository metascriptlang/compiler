// Operator Lowering — rewrite binary ops to function calls when operator overload exists
//
// reference parity: reference core defines `proc \`==\`*[T: tuple|object](x, y: T): bool`
// and semantic analysis resolves `a == b` into `\`==\`(a, b)` as a normal call.
// Codegen never sees struct == struct.
//
// This transform does the same: when a BinaryExpr's operand type has a matching
// operator function registered in ExtensionRegistry, rewrite to CallExpr.
// Built-in types (number, string, boolean) are never rewritten.
//
// reference parity coverage:
//   reference core:1973  — proc `==`*[T: tuple|object]  → auto-generated _eq
//   reference core:1980  — proc `<=`*[T: tuple]          → auto-generated _le
//   reference core:1989  — proc `<`*[T: tuple]           → auto-generated _lt
//   reference comparisons  — template `!=` = not(==)        → derived from ==
//   reference comparisons  — template `>` = y < x           → derived from <
//   reference comparisons  — template `>=` = y <= x         → derived from <=

import { Node, NodeKind, BinaryExprData, ExprStmtData, NewExprData, UnaryExprData, IdentifierData, MemberExprData, TypeAssertionData, SourceLocation, Type, TypeKind, Symbol, SymbolKind, AttachedOp, NodeFlag } from "../../ast/node";
import { TransformContext, PendingTupleOp, reportTransformError } from "../context";
import { liftedOp, hookBaseCName, hasUnionEq, anonUnionCName, opTypeKey } from "../../codegen/c/types";
import { walkNode, hasEffect } from "../walker";
import { cloneIdent, makeCall, makeUnary, makeBool, makeMember, makeBinary, makeNull, receiverKind, makeTypedIdentResolved } from "../util";
import { typeNameOf, tupleTypeName, createFunction, booleanType, isMaybeType, isResult, isStringLike, unwrapRefNullUnion, peelThrough, PEEL_ALIAS, peelTransparentInstance, isAwaitable, peelToStructOrUnion, isStdCollectionKind } from "../../checker/types";
import { cloneIfPure } from "../coercion/intArithJS";
import { resolveOperatorCall, ExtensionMethod, getExtFnType, declaredKeyHash } from "../../checker/context";

// The checker binds every operator a routine in scope is declared for; an operator that reaches
// lowering unbound calls a prelude or extension operator, the same one in every scope.
function extensionOperator(ctx: TransformContext, op: string, types: Type[]): ExtensionMethod {
	return resolveOperatorCall(null, ctx.checkerCtx.extensionRegistry, op, types);
}

// ===== Type Resolution =====

// Resolve the Type of an expression node.
// Tries nodeType first (set by checker/analyzer), then resolvedSym.
function resolveType(ctx: TransformContext, node: Node): Type | null {
	if (node.nodeType != null) return node.nodeType;
	if (node.resolvedSym != null && node.resolvedSym.symbolType != null) {
		return node.resolvedSym.symbolType;
	}
	return null;
}

// Built-in types that use native C operators — never rewrite these.
// String is NOT builtin — it has operator overloads (==, <, <=) in prelude.
function isBuiltinOperand(t: Type | null): boolean {
	return match (receiverKind(t)) {
		TypeKind.Number | TypeKind.Boolean | TypeKind.Float32 | TypeKind.Float64 => true,
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => true,
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => true,
		_ => false,
	};
}



// ===== Null Detection =====

// Recursively unwrap TypeAssertion to detect null expressions.
// `null` → TypeAssertion(TypeAssertion(NullLiteral, "unknown"), "Type")
export function isNullExpr(node: Node): boolean {
	if (node.kind == NodeKind.NullLiteral) return true;
	if (node.kind == NodeKind.TypeAssertion) return isNullExpr((node.data as TypeAssertionData).asExpr);
	return false;
}

// ===== Operator Resolution =====

// Check if a type is a value-type object (interface) — candidate for auto-generated ==.
// Excludes Maybe<T> types which need special null comparison handling.
function isValueObject(t: Type): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.GenericInstance) return isStructInstance(t);
	if (t.kind != TypeKind.Struct) return false;
	if (isMaybeType(t)) return false;
	return t.typeName != "";
}

function isStructInstance(t: Type): boolean {
	if (t.typeName == "" || isAwaitable(t)) return false;
	const nominal = peelToStructOrUnion(t.typeExtra);
	return nominal != null && nominal.kind == TypeKind.Struct;
}

function maybeCarrierOf(side: Node): Node | null {
	if (side.kind != NodeKind.MemberExpr) return null;
	const md = side.data as MemberExprData;
	if (md.property != "value" || md.object == null || md.object.nodeType == null || !isMaybeType(md.object.nodeType)) return null;
	return md.object;
}

function hasValueEq(t: Type): boolean {
	return isValueObject(t) || t.kind == TypeKind.SizedArray;
}

// A type that can never hold null: comparing it with `null` is a constant.
// `Union(Ref<T>, Null)` / `Union(Ptr<T>, Null)` is the nullable pointer pattern and
// stays a runtime check, as does a Maybe carrier.
function neverHoldsNull(t: Type): boolean {
	if (hasValueEq(t)) return true;
	if (isMaybeType(t)) return false;
	const vk = t.kind;
	if (vk == TypeKind.Array || vk == TypeKind.GenericInstance || vk == TypeKind.Tuple || vk == TypeKind.String || vk == TypeKind.BigInt) return true;
	return vk == TypeKind.Union && unwrapRefNullUnion(t) == null;
}

// The operand of an `==`/`!=` against `null` whose answer is a constant, else null.
// Every pass that must keep that operand's evaluation asks this one question.
export function foldedNullOperand(ctx: TransformContext, node: Node): Node | null {
	if (node.kind != NodeKind.BinaryExpr || ctx.checkerCtx == null) return null;
	const d = node.data as BinaryExprData;
	const op = d.operator;
	if (op != "==" && op != "===" && op != "!=" && op != "!==") return null;
	const nullLeft = isNullExpr(d.left);
	if (nullLeft == isNullExpr(d.right)) return null;
	const operand = nullLeft ? d.right : d.left;
	let valueType = resolveType(ctx, operand);
	if (valueType != null && !nullLeft) {
		const peeled = peelThrough(valueType, PEEL_ALIAS);
		valueType = peelTransparentInstance(peeled != null ? peeled : valueType);
	}
	return valueType != null && neverHoldsNull(valueType) ? operand : null;
}

function declaresEquality(ctx: TransformContext, leftType: Type, right: Node): boolean {
	if (ctx.checkerCtx.extensionRegistry == null) return false;
	const rt = resolveType(ctx, right);
	const pair = [leftType, rt != null ? rt : leftType];
	return extensionOperator(ctx, "==", pair) != null
		|| extensionOperator(ctx, "!=", pair) != null;
}

function comparedByValue(left: Type, right: Type | null): boolean {
	const other = right != null ? peelTransparentInstance(right) : null;
	const shapes = [left, other];
	for (const t of shapes) {
		if (t == null) continue;
		if (hasValueEq(t) || t.kind == TypeKind.Tuple || t.kind == TypeKind.Array || isMaybeType(t) || isResult(t)) return true;
	}
	return false;
}

function unionOperandsAgree(ctx: TransformContext, leftType: Type, right: Node): boolean {
	const rt = resolveType(ctx, right);
	if (rt == null) return false;
	const peeled = peelThrough(rt, PEEL_ALIAS);
	const other = peelTransparentInstance(peeled != null ? peeled : rt);
	return other.kind == TypeKind.Union && opTypeKey(other) == opTypeKey(leftType);
}

function unionEqName(ctx: TransformContext, t: Type): string {
	if (t.typeName == "") return anonUnionCName(t);
	return hookBaseCName(t.typeName, t, ctx.checkerCtx);
}

// Register a pending tuple operation for later generation by destructorLifting.
function registerTupleOp(ctx: TransformContext, t: Type, tName: string, op: string): void {
	// Find existing entry for this tuple
	let i = 0;
	while (i < ctx.pendingTupleOps.length) {
		if (ctx.pendingTupleOps[i].tupleName == tName) {
			// Add op if not already present
			let found = false;
			for (const existing of ctx.pendingTupleOps[i].ops) {
				if (existing == op) { found = true; }
			}
			if (!found) ctx.pendingTupleOps[i].ops.push(op);
			return;
		}
		i += 1;
	}
	// Create new entry
	const entry: PendingTupleOp = { tupleType: t, tupleName: tName, ops: [op] };
	ctx.pendingTupleOps.push(entry);
}

function registerUnionEq(ctx: TransformContext, t: Type): void {
	for (const pending of ctx.pendingUnionEqs) {
		if (pending == t) return;
	}
	ctx.pendingUnionEqs.push(t);
}

// A checked operator the program declares a routine for is a call of the routine the checker bound
// in the scope the operator is written in.
function lowerBoundOperator(node: Node, routine: Symbol): Node {
	const loc = node.location;
	if (node.kind == NodeKind.UnaryExpr) return makeRoutineCall(routine, [(node.data as UnaryExprData).operand], loc);
	const d = node.data as BinaryExprData;
	if (!node.flags.has(NodeFlag.UserOpStores)) return makeRoutineCall(routine, [d.left, d.right], loc);
	return makeBinary(d.left, "=", makeRoutineCall(routine, [cloneLvalue(d.left), d.right], loc), loc);
}

function boundOperator(node: Node): Symbol | null {
	if (!node.flags.has(NodeFlag.UserOp)) return null;
	if (node.resolvedSym == null) throw new Error("internal: a declared operator reached lowering without the routine the checker bound");
	return node.resolvedSym;
}

function makeRoutineCall(routine: Symbol, args: Node[], loc: SourceLocation): Node {
	const call = makeCall(makeTypedIdentResolved(routine, null, loc), args, loc);
	const fnType = routine.symbolType;
	if (fnType != null && fnType.kind == TypeKind.Function && fnType.typeReturn != null) call.nodeType = fnType.typeReturn;
	return call;
}

// Build a call to an operator extension — resolves nativeName for extern operators.
function makeExtOpCall(ext: ExtensionMethod, opName: string, left: Node, right: Node, loc: SourceLocation): Node {
	if (ext.sym == null) {
		throw new Error(`internal: operator '${opName}' resolved to an extension without a symbol`);
	}
	return makeRoutineCall(ext.sym, [left, right], loc);
}

// Resolve a base operator to a CallExpr.
function resolveOpCall(ctx: TransformContext, typeName: string, opName: string, leftType: Type, left: Node, right: Node, loc: SourceLocation): Node {
	// Explicit user declaration takes priority. Same candidate set as the entry
	// resolution — a derived operator must reach a flat `function `==`(a, b)`
	// exactly as the direct form does, or `a == b` and `a != b` disagree.
	{
		const rt = resolveType(ctx, right);
		const ext = extensionOperator(ctx, opName, [leftType, rt != null ? rt : leftType]);
		if (ext != null) {
			return makeExtOpCall(ext, opName, left, right, loc);
		}
	}
	// Auto-generated ==, <, <= for tuples (reference: reference core:1973-1996)
	if (leftType.kind == TypeKind.Tuple) {
		const tName = tupleTypeName(leftType);
		if (tName == "") return null as unknown as Node;
		const suffix = match (opName) {
			"<" => "Lt",
			"<=" => "Le",
			_ => "",
		};
		if (suffix != "") {
			registerTupleOp(ctx, leftType, tName, suffix);
			const fnType = createFunction([leftType, leftType], ["x", "y"], booleanType());
			const tupleOp = suffix == "Lt" ? AttachedOp.AttachedLt : AttachedOp.AttachedLe;
			return makeCall(makeTypedIdentResolved(liftedOp(leftType, tupleOp, tName + suffix, fnType), fnType, loc), [left, right], loc);
		}
	}
	return null as unknown as Node;
}

// ===== Visitor =====

function cloneLvalue(node: Node): Node {
	if (node.kind == NodeKind.Identifier) {
		return cloneIdent(node, node.location);
	}
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		const c = makeMember(cloneLvalue(d.object), d.property, node.location);
		c.nodeType = node.nodeType;
		c.resolvedSym = node.resolvedSym;
		return c;
	}
	return node;
}

// Closure equality: a === b -> a.fn === b.fn && a.env === b.env (reference parity). Only a
// plain path operand is read twice; any other operand is left as written.
function lowerClosureEquality(node: Node, opName: string, left: Node, right: Node, loc: SourceLocation): Node {
	const readsTwice = (n: Node): boolean => n.kind == NodeKind.Identifier || n.kind == NodeKind.MemberExpr;
	if (!readsTwice(left) || !readsTwice(right)) return node;
	const fnEq = makeBinary(makeMember(cloneLvalue(left), "fn", loc), "===", makeMember(cloneLvalue(right), "fn", loc), loc);
	const envEq = makeBinary(makeMember(left, "env", loc), "===", makeMember(right, "env", loc), loc);
	const bothEq = makeBinary(fnEq, "&&", envEq, loc);
	if (opName == "!=" || opName == "!==") return makeUnary("!", bothEq, loc);
	return bothEq;
}

function lowerUnaryNode(node: Node, ctx: TransformContext): Node {
	const bound = boundOperator(node);
	if (bound != null) return lowerBoundOperator(node, bound);
	if (ctx.checkerCtx == null) return node;
	if (ctx.checkerCtx.extensionRegistry == null) return node;
	const d = node.data as UnaryExprData;
	const op = d.unaryOp;
	if (op != "-" && op != "+" && op != "!" && op != "~") return node;
	const t = resolveType(ctx, d.operand);
	if (t == null) return node;
	if (isStringLike(t)) return node;
	const typeName = typeNameOf(t);
	if (typeName == "" || isBuiltinOperand(t)) return node;
	const ext = extensionOperator(ctx, op, [t]);
	if (ext == null) return node;
	if (ext.sym == null) {
		throw new Error(`internal: operator '${op}' resolved to an extension without a symbol`);
	}
	const call = makeCall(makeTypedIdentResolved(ext.sym, null, node.location), [d.operand], node.location);
	const fnType = getExtFnType(ext);
	if (fnType != null && fnType.typeReturn != null) call.nodeType = fnType.typeReturn;
	return call;
}

function lowerOperatorNode(node: Node, ctx: TransformContext): Node {
	if (node.kind == NodeKind.UnaryExpr) return lowerUnaryNode(node, ctx);
	if (node.kind != NodeKind.BinaryExpr) return node;
	const bound = boundOperator(node);
	if (bound != null) return lowerBoundOperator(node, bound);
	if (ctx.checkerCtx == null) return node;

	const d = node.data as BinaryExprData;
	const opName = d.operator;
	const isNotEqual = opName == "!=" || opName == "!==";

	let leftType = resolveType(ctx, d.left);
	if (leftType != null) {
		const leftPeeled = peelThrough(leftType, PEEL_ALIAS);
		if (leftPeeled != null) leftType = leftPeeled;
		if (leftType != null) leftType = peelTransparentInstance(leftType);
	}
	const loc = node.location;

	const compoundBase = match (opName) {
		"+=" => "+",
		"-=" => "-",
		"*=" => "*",
		"/=" => "/",
		"%=" => "%",
		"**=" => "**",
		_ => "",
	};
	if (compoundBase != "" && leftType != null
		&& (d.left.kind == NodeKind.Identifier || d.left.kind == NodeKind.MemberExpr)
		&& ctx.checkerCtx.extensionRegistry != null) {
		const ltName = isStringLike(leftType) ? "string" : typeNameOf(leftType);
		if (ltName != "" && !isBuiltinOperand(leftType)) {
			const crt = resolveType(ctx, d.right);
			const cext = crt != null ? extensionOperator(ctx, compoundBase, [leftType, crt]) : null as unknown as ExtensionMethod;
			if (cext != null) {
				const rhsCall = makeExtOpCall(cext, compoundBase, cloneLvalue(d.left), d.right, loc);
				return makeBinary(d.left, "=", rhsCall, loc);
			}
		}
	}

	// 3. Null comparisons — check BEFORE typeName guard since null has typeName=""
	// reference parity: objects can't be nil (reference comparisons, reference core)
	// EQUALITY ops only: `x = null` is an assignment — rewriting it into a
	// present-check would silently DROP the store (nullableLower wraps the
	// null for Maybe assignment instead).
	const isNullEqOp = opName == "==" || opName == "===" || opName == "!=" || opName == "!==";
	const hasNullLeft = isNullExpr(d.left);
	const hasNullRight = isNullExpr(d.right);
	if (isNullEqOp && (hasNullLeft || hasNullRight)) {
		const carrier = maybeCarrierOf(hasNullLeft ? d.right : d.left);
		if (carrier != null && hasNullLeft) d.right = carrier;
		else if (carrier != null) d.left = carrier;
		const valueType = carrier != null ? carrier.nodeType : hasNullLeft ? resolveType(ctx, d.right) : leftType;
		// The operand is still evaluated once, in order: awaitSpill binds an impure one to a
		// temp on C. JS and the Raiser compare with null natively, so they keep the comparison.
		const folded = foldedNullOperand(ctx, node);
		if (folded != null) {
			if (cloneIfPure(folded) != null) return makeBool(isNotEqual, loc);
			if (ctx.jsBackend || ctx.raiserBackend) return node;
			if (hasEffect(folded)) reportTransformError(ctx, "internal: a null comparison on an operand with effects reached operatorLower unspilled", loc);
			return makeBool(isNotEqual, loc);
		}
		// Maybe<T>: x !== null → x.present, x === null → !x.present
		if (valueType != null && isMaybeType(valueType)) {
			const nonNullSide = hasNullLeft ? d.right : d.left;
			const member = makeMember(nonNullSide, "present", loc);
			if (isNotEqual) return member;
			return makeUnary("!", member, loc);
		}
		// Closure null check: `closure === null` → `closure.fn === NULL`.
		// Both sides re-bound: the null side must be a bare null literal — a
		// typed `null as Closure` codegens as `(msClosure){0}` and mismatches
		// the function pointer field on the other side.
		if (valueType != null && valueType.kind == TypeKind.Function) {
			const nonNullSide = hasNullLeft ? d.right : d.left;
			const fnMember = makeMember(nonNullSide, "fn", loc);
			const bareNull = makeNull(loc);
			d.left = hasNullLeft ? bareNull : fnMember;
			d.right = hasNullLeft ? fnMember : bareNull;
			return node;
		}
	}

	if (leftType != null && !ctx.jsBackend && leftType.kind == TypeKind.Function && isNullEqOp && !hasNullLeft && !hasNullRight) {
		return lowerClosureEquality(node, opName, d.left, d.right, loc);
	}

	if (leftType == null) return node;
	// StringLiteral and Union<StringLiteral...> are string at runtime — use string operators
	let typeName = isStringLike(leftType) ? "string" : typeNameOf(leftType);
	if (typeName == "") return node;

	// 1. Explicit user-defined operator overload takes priority (reference parity:
	//    user overloads beat magic builtins). Checked BEFORE isBuiltinType
	//    so that e.g. `==`(a: int32, b: int32) overrides native ==.
	if (ctx.checkerCtx.extensionRegistry != null) {
		const rt = resolveType(ctx, d.right);
		const ext = rt != null ? extensionOperator(ctx, opName, [leftType, rt]) : null as unknown as ExtensionMethod;
		if (ext != null) {
			return makeExtOpCall(ext, opName, d.left, d.right, loc);
		}
	}

	// 2a. String operators (==, !=, <, >, <=, >=) handled by operator overloads in prelude.
	// No hardcoded lowering — the overloads are registered as extensions and found above.

	// 2b. Built-in types use native C operators — no rewrite needed.
	if (isBuiltinOperand(leftType)) return node;

	// 4. Derived operators — fallback for types without explicit prelude overloads.
	// 4. Derived operators — fallback for types without prelude overloads.
	// Strings define ALL operators in prelude (found in step 1 above).
	// Interfaces/tuples use compiler derivation until templates exist.
	const baseOp = match (opName) {
		"===" => "==",
		_ => "",
	};
	if (baseOp != "") {
		let hasBase = false;
		if (extensionOperator(ctx, baseOp, [leftType, leftType]) != null) hasBase = true;

		if (hasBase) {
			const derived = resolveOpCall(ctx, typeName, baseOp, leftType, d.left, d.right, loc);
			if (derived != null) return derived;
		}
	}

	// 5. A named or anonymous payload union compares by tag, then payload (C only; JS `===` already does).
	if (!ctx.jsBackend && hasUnionEq(leftType) && unionOperandsAgree(ctx, leftType, d.right)
		&& (opName == "==" || opName == "===" || opName == "!=" || opName == "!==")) {
		const eqName = unionEqName(ctx, leftType);
		registerUnionEq(ctx, leftType);
		const fnType = createFunction([leftType, leftType], ["x", "y"], booleanType());
		const eqCall = makeCall(makeTypedIdentResolved(liftedOp(leftType, AttachedOp.AttachedEq, eqName + "Eq", fnType), fnType, loc), [d.left, d.right], loc);
		return isNotEqual ? makeUnary("!", eqCall, loc) : eqCall;
	}

	// 6. Ordering of tuples (auto-generated <, <=).
	//    Reference: reference core:1989 (<), :1980 (<=)
	if (leftType.kind == TypeKind.Tuple && (opName == "<" || opName == "<=")) {
		const resolved = resolveOpCall(ctx, typeName, opName, leftType, d.left, d.right, loc);
		if (resolved != null) return resolved;
	}

	if (isNullEqOp && !hasNullLeft && !hasNullRight && comparedByValue(leftType, resolveType(ctx, d.right)) && !declaresEquality(ctx, leftType, d.right)) {
		throw new Error(`internal: '${opName}' over a value type reached lowering; the checker rewrites it to the std equality`);
	}

	return node;
}

// ===== Entry Point =====

export function lowerOperators(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return lowerOperatorNode(node, ctx);
	});
}

export function lowerUserOperators(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		return node.flags.has(NodeFlag.UserOp) ? lowerOperatorNode(node, ctx) : node;
	});
}

function constructedCollectionKey(node: Node): Type | null {
	const called = (node.data as NewExprData).newCallee.resolvedSym;
	const sym = called != null && called.instantiatedFrom != null ? called.instantiatedFrom : called;
	if (sym == null || !isStdCollectionKind(sym.builtinKind)) return null;
	let t = node.nodeType;
	if (t != null && (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) && t.typeReturn != null) t = t.typeReturn;
	return t != null && t.kind == TypeKind.GenericInstance && t.typeChildren.length > 0 ? t.typeChildren[0] : null;
}

function keyOpRef(sym: Symbol | null, loc: SourceLocation): Node {
	return sym != null ? makeTypedIdentResolved(sym, sym.symbolType, loc) : makeNull(loc);
}

export function bindCollectionKeyOps(program: Node, ctx: TransformContext): Node {
	if (ctx.checkerCtx == null || ctx.checkerCtx.extensionRegistry == null) return program;
	return walkNode(program, (node: Node): Node => {
		if (node.kind != NodeKind.NewExpr || node.flags.has(NodeFlag.KeyOps)) return node;
		const keyType = constructedCollectionKey(node);
		if (keyType == null) return node;
		const peeled = peelThrough(keyType, PEEL_ALIAS);
		if (peeled == null) return node;
		const shape = peelTransparentInstance(peeled);
		if (!hasValueEq(shape) && shape.kind != TypeKind.Tuple) return node;
		const eq = resolveOperatorCall(ctx.checkerCtx.table, ctx.checkerCtx.extensionRegistry, "==", [keyType, keyType]);
		const hash = declaredKeyHash(ctx.checkerCtx.extensionRegistry, keyType);
		if (eq == null && hash == null) return node;
		const d = node.data as NewExprData;
		const loc = node.location;
		d.newArguments = [d.newArguments.length > 0 ? d.newArguments[0] : makeNull(loc), keyOpRef(hash, loc), keyOpRef(eq != null ? eq.sym : null, loc)];
		node.flags = node.flags.incl(NodeFlag.KeyOps);
		return node;
	});
}

// ===== Tests =====

import { createContext, createExtensionRegistry, registerExtension } from "../../checker/context";
import { createStruct, createFunction, createTuple, createRef, createPtr, createMaybeType, inferredType, numberType, stringType, booleanType } from "../../checker/types";
import { defineSymbol, makeSymbol, lookupSymbol, SymbolTable } from "../../checker/symbol";
import { forEachChild } from "../../ast/visitor";
import { createTransformContextWithChecker } from "../context";
import { parseInput, getStmts, firstExprKind } from "../testUtil";
import { ExprStmtData } from "../../ast/node";

function bindFromTable(node: Node, table: SymbolTable): void {
	if (node.kind == NodeKind.Identifier) {
		const sym = lookupSymbol(table, (node.data as IdentifierData).name);
		if (sym != null) node.resolvedSym = sym;
	}
	forEachChild(node, (child: Node): void => {
		bindFromTable(child, table);
	});
}

function lowerBound(program: Node, ctx: TransformContext): Node {
	bindFromTable(program, ctx.checkerCtx!.table);
	return lowerOperators(program, ctx);
}

function makeOpExt(opName: string): ExtensionMethod {
	const fnType = createFunction([inferredType(), inferredType()], ["a", "b"], inferredType());
	return {
		methodName: opName,
		sourcePath: "",
		isStatic: false,
		sym: makeSymbol(opName, SymbolKind.Function, fnType, false),
	};
}

function setupCtx(typeName: string, opName: string): TransformContext {
	const checkerCtx = createContext();
	const registry = createExtensionRegistry();
	registerExtension(registry, makeOpExt(opName));
	checkerCtx.extensionRegistry = registry;
	const objType = createStruct(typeName, [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	return createTransformContextWithChecker(checkerCtx);
}

function setupTupleCtx(): TransformContext {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const tupType = createTuple([numberType(), stringType()]);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, tupType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, tupType, false));
	return createTransformContextWithChecker(checkerCtx);
}

// ===== Object operator tests =====

test "operator lower rewrites === on interface types" {
	const ctx = setupCtx("Token", "==");
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	const stmts = getStmts(result);
	assert stmts.length > 0;
	assert stmts[0].kind == NodeKind.ExprStmt;
}

test "operator lower does not rewrite builtin types without override" {
	// No explicit extension for number — native == used
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const numType = inferredType(); // number-like
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, numType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, numType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "operator lower rewrites builtin type with explicit override" {
	// User-defined override for number == — takes priority over native ==
	const ctx = setupCtx("number", "==");
	const pr = parseInput("a == b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	// Explicit extension registered → rewritten to CallExpr
	assert firstExprKind(result) == NodeKind.CallExpr;
}

test "== over a value type is refused at lowering: the checker routes it to the std equality" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Token", [], [], true);
	objType.sym = makeSymbol("Token", SymbolKind.Interface, objType, false);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	let refused = false;
	try {
		lowerBound(pr.value, ctx);
	} catch (e) {
		refused = true;
	}
	assert refused;
}

test "operator lower does not rewrite Ref types" {
	// Classes (Ref<Object>) are reference types — no auto-generated ==
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createRef(createStruct("MyClass", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

// ===== Derived operator tests (reference: system/reference comparisons) =====

test "!== over a value type is refused at lowering as well" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	let refused = false;
	try {
		lowerBound(pr.value, ctx);
	} catch (e) {
		refused = true;
	}
	assert refused;
}

test "!= is not derived from an explicit == extension" {
	const ctx = setupCtx("Coord", "==");
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "> is not derived from <" {
	const ctx = setupCtx("Vec", "<");
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test ">= is not derived from <=" {
	const ctx = setupCtx("Vec", "<=");
	const pr = parseInput("a >= b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "> not derived without < defined" {
	// No < extension → > stays as BinaryExpr
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Vec", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "explicit != overrides derivation from ==" {
	// User defines both == and !== — !== uses explicit, not derived
	const checkerCtx = createContext();
	const registry = createExtensionRegistry();
	registerExtension(registry, makeOpExt("=="));
	registerExtension(registry, makeOpExt("!=="));
	checkerCtx.extensionRegistry = registry;
	const objType = createStruct("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, objType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a !== b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	// Explicit !== extension → direct CallExpr (not UnaryExpr wrapping)
	assert firstExprKind(result) == NodeKind.CallExpr;
}

// ===== Tuple operator tests (reference: reference core:1973-1996) =====

test "tuple === is refused at lowering: the checker routes it to the std equality" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	let refused = false;
	try {
		lowerBound(pr.value, ctx);
	} catch (e) {
		refused = true;
	}
	assert refused;
	assert ctx.pendingTupleOps.length == 0;
}

test "closure === compares the fn word and the env word on C" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const fnType = createFunction([], [], numberType());
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, fnType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, fnType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	const stmt = getStmts(result)[0].data as ExprStmtData;
	assert stmt.expr.kind == NodeKind.BinaryExpr;
	assert (stmt.expr.data as BinaryExprData).operator == "&&";
}

test "closure === is left to the JS backend" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const fnType = createFunction([], [], numberType());
	defineSymbol(checkerCtx.table, makeSymbol("a", SymbolKind.Variable, fnType, false));
	defineSymbol(checkerCtx.table, makeSymbol("b", SymbolKind.Variable, fnType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	ctx.jsBackend = true;
	const pr = parseInput("a === b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	const stmt = getStmts(result)[0].data as ExprStmtData;
	assert (stmt.expr.data as BinaryExprData).operator == "===";
}

test "tuple < rewrites to _lt call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a < b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.CallExpr;
}

test "tuple <= rewrites to Le call" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a <= b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.CallExpr;
}

test "tuple > is not derived at transform time" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a > b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "tuple >= is not derived at transform time" {
	const ctx = setupTupleCtx();
	const pr = parseInput("a >= b;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "pending tuple ops dedup" {
	const ctx = setupTupleCtx();
	const pr1 = parseInput("a < b;");
	if (!pr1.ok) return;
	lowerBound(pr1.value, ctx);
	const pr2 = parseInput("a < b;");
	if (!pr2.ok) return;
	lowerBound(pr2.value, ctx);
	// Same tuple type used twice — should only have 1 pending entry
	assert ctx.pendingTupleOps.length == 1;
}

// ===== Nullable Pointer Tests =====

test "Ref !== null is NOT constant-folded" {
	// Ref<Object> is a pointer type — null comparison should pass through
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const refType = createRef(createStruct("MyClass", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("x", SymbolKind.Variable, refType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("x !== null;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	// Should remain BinaryExpr (not constant-folded to BooleanLiteral)
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "Ptr !== null is NOT constant-folded" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const ptrType = createPtr(createStruct("Buffer", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("p", SymbolKind.Variable, ptrType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("p !== null;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	assert firstExprKind(result) == NodeKind.BinaryExpr;
}

test "Maybe<Interface> !== null rewrites to .present" {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const maybeType = createMaybeType(createStruct("Token", [], [], true));
	defineSymbol(checkerCtx.table, makeSymbol("t", SymbolKind.Variable, maybeType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("t !== null;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	// Should rewrite to t.present → MemberExpr
	assert firstExprKind(result) == NodeKind.MemberExpr;
}

test "interface !== null constant-folds to true" {
	// Plain interface (non-nullable) — null comparison is always true
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const objType = createStruct("Token", [], [], true);
	defineSymbol(checkerCtx.table, makeSymbol("t", SymbolKind.Variable, objType, false));
	const ctx = createTransformContextWithChecker(checkerCtx);
	const pr = parseInput("t !== null;");
	if (!pr.ok) return;
	const result = lowerBound(pr.value, ctx);
	// Should constant-fold to BooleanLiteral(true)
	assert firstExprKind(result) == NodeKind.BooleanLiteral;
}

function unspilledNullCheckErrors(input: string): int32 {
	const checkerCtx = createContext();
	checkerCtx.extensionRegistry = createExtensionRegistry();
	const pr = parseInput(input);
	if (!pr.ok) return -1;
	const comparison = (getStmts(pr.value)[0].data as ExprStmtData).expr;
	(comparison.data as BinaryExprData).left.nodeType = createStruct("Token", [], [], true);
	lowerOperators(pr.value, createTransformContextWithChecker(checkerCtx));
	return checkerCtx.errors.length as int32;
}

test "a never-null call that reaches the null comparison unspilled is refused" {
	assert unspilledNullCheckErrors("make() !== null;") == 1;
}

test "a never-null read through a cast folds its null comparison without a spill" {
	assert unspilledNullCheckErrors("(env as Env).token !== null;") == 0;
}
