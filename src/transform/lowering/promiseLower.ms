// Promise Lowering — rewrites @builtin("Promise*") / waitFor / new Promise
// calls into runtime intrinsics. Extracted from `builtinLower.ms` so all
// Promise-related transform logic lives in one cohesive module, alongside
// the other async/spawn lowering passes (asyncBridge.ms, awaitLower.ms,
// spawnGroupLower.ms).
//
// Dispatched from `builtinLower.ms:lowerBuiltinCall` via `tryLowerPromiseBuiltin`
// — returns a rewritten Node when the builtinKind belongs to the Promise family,
// otherwise returns null so the caller continues with other handlers.
//
// What lives here:
//   - per-T suffix/dispatch helpers (futureTypedSuffix, futureThenFnForInner,
//     futureCatchFnForInner, futureFinallyFnForInner, promiseAllFnForInner,
//     typedFutureReadFn)
//   - box/unbox helpers for primitive values flowing through msFuture* slots
//   - typeTagFor (int/double/string/ptr tag dispatch for msFutureThenTyped etc.)
//   - handlers for PromiseThen / PromiseCatch / PromiseFinally / PromiseResolve
//     / PromiseSpawn / PromiseAll / WaitFor
//   - `new Promise(executor)` rewrite
//
// The future storage contract (inlineInFuture / boxedInFuture) lives in `../util`
// — shared by asyncBridge, builtinLower, and promiseLower. Keeping it in any one
// of them would create a circular import.

import { Node, NodeKind, SourceLocation, CallExprData, MemberExprData, NewExprData, Type, TypeKind } from "../../ast/node";
import { isAwaitable, awaitedType } from "../../checker/types";
import { TransformContext } from "../context";
import { makeIdent, makeCall, makeNumber, makeNull, inlineInFuture, unboxVoidPtrToTyped } from "../util";

// ===== Type-tag dispatch =====

// Runtime type-tag for msFutureThenTyped / msFutureCatchTyped. Matches
// MS_TYPETAG_* in runtime/promise/combinator.h (0=ptr, 1=int, 2=double, 3=string).
function typeTagFor(t: Type | null): number {
	if (t === null) return 0;
	return match (t.kind) {
		TypeKind.Void => 0,
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => 2,
		TypeKind.String => 3,
		TypeKind.Struct | TypeKind.Ref | TypeKind.Ptr | TypeKind.Array => 0,
		_ => 1,  // int8-64, uint8-64, bool, enum — all fit in void*
	};
}

// ===== Per-T suffix + dispatch name helpers =====

// Map Promise<T> inner type to the typed T suffix used by msFuture*_<T>
// variants (Chain, Then, Catch, Finally). Returns "" if no typed variant
// exists (caller must fall back to the untyped/boxed path).
// Correct for futures with inline typed storage (populated via msFutureCompleteT).
function futureTypedSuffix(t: Type | null): string {
	if (t === null) return "";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "double",
		TypeKind.Int32 | TypeKind.Int16 | TypeKind.Int8
			| TypeKind.Uint32 | TypeKind.Uint16 | TypeKind.Uint8
			| TypeKind.Enum => "int32",
		TypeKind.Int64 | TypeKind.Uint64 => "int64",
		TypeKind.Boolean => "bool",
		TypeKind.String => "msString",
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Function => "ptr",
		_ => "",  // struct, array, void, unknown → fall through to boxed path
	};
}

function futureThenFnForInner(t: Type | null): string {
	const suffix = futureTypedSuffix(t);
	return suffix === "" ? "" : "msFutureThen_" + suffix;
}

function futureCatchFnForInner(t: Type | null): string {
	const suffix = futureTypedSuffix(t);
	return suffix === "" ? "" : "msFutureCatch_" + suffix;
}

function futureFinallyFnForInner(t: Type | null): string {
	const suffix = futureTypedSuffix(t);
	return suffix === "" ? "" : "msFutureFinally_" + suffix;
}

// Per-type Promise.all variant name — picks msPromiseAllFor_msFuture_<suffix>
// for primitive/string/ptr/struct inner types. Returns "" only for void/array
// (those fall through to legacy generic msPromiseAll). Struct types use their
// declared typeName which matches codegen's mangle(getTypeDesc(t)) for simple
// names — genFutureType emits the matching MS_PROMISE_ALL_FOR instance.
function promiseAllFnForInner(t: Type | null): string {
	const suffix = futureTypedSuffix(t);
	if (suffix !== "") return "msPromiseAllFor_msFuture_" + suffix;
	if (t !== null && t.kind === TypeKind.Struct && t.typeName !== "") {
		return "msPromiseAllFor_msFuture_" + t.typeName;
	}
	return "";
}

// Typed future readers — msFutureReadT reads the typed inline value from
// the future struct (msFuture_T.value). All futures use typed inline
// storage; no boxed path exists.
// Exported for awaitLower.ms which selects the typed read per Promise<T>.
export function typedFutureReadFn(t: Type): string {
	if (t === null) return "";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "msFutureReadDouble",
		TypeKind.Boolean => "msFutureReadBool",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "msFutureReadInt32",
		TypeKind.String => "msFutureReadString",
		_ => "",
	};
}

// ===== Call-construction helpers =====

// Build a call to `fnName(args...)` and tag it with the requested result type.
// Consolidates the "makeCall + nodeType + return" pattern used by builtin
// replacements.
function mkTypedCall(fnName: string, args: Node[], nodeType: Type | null, loc: SourceLocation): Node {
	const call = makeCall(makeIdent(fnName, loc), args, loc);
	call.nodeType = nodeType;
	return call;
}

// Box a value for void* storage in msFuture (Promise.resolve, spawn return).
// Primitives get packed into the void* bits via msBox*; struct/string values
// pass through unchanged (caller uses typed inline storage instead).
function boxValueForFuture(node: Node, loc: SourceLocation): Node {
	if (node === null) return makeNull(loc);
	if (node.nodeType === null) return node;
	return match (node.nodeType.kind) {
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => makeCall(makeIdent("msBoxDouble", loc), [node], loc),
		TypeKind.Boolean => makeCall(makeIdent("msBoxBool", loc), [node], loc),
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 |
		TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => makeCall(makeIdent("msBoxInt32", loc), [node], loc),
		_ => node,
	};
}

// ===== Builtin handlers =====

// Promise.then/catch/finally — rewrite to typed C runtime calls.
// Typed variants (msFutureThen_<T>, msFutureCatch_<T>, msFutureFinally_<T>)
// read input.value via the correct typed struct cast, preserving msString
// (16B) and primitive widths on pass-through. Struct/array/void/unknown
// fall back to the legacy tag-dispatch path.
function lowerPromiseThenCatchFinally(node: Node, builtinKind: string, loc: SourceLocation): Node {
	const cd = node.data as CallExprData;
	if (cd.callee.kind !== NodeKind.MemberExpr || cd.arguments.length < 1) return node;
	const me = cd.callee.data as MemberExprData;
	const innerType = awaitedType(me.object.nodeType);
	const cb = cd.arguments[0];
	return match (builtinKind) {
		"PromiseThen" => {
			const typedFn = futureThenFnForInner(innerType);
			if (typedFn !== "") return mkTypedCall(typedFn, [me.object, cb], node.nodeType, loc);
			const tag = typeTagFor(innerType);
			return mkTypedCall("msFutureThenTyped", [me.object, cb, makeNumber(tag, loc)], node.nodeType, loc);
		},
		"PromiseCatch" => {
			// Error handler always receives msString (MetaScript errors are strings).
			const typedFn = futureCatchFnForInner(innerType);
			if (typedFn !== "") return mkTypedCall(typedFn, [me.object, cb], node.nodeType, loc);
			return mkTypedCall("msFutureCatchTyped", [me.object, cb, makeNumber(3, loc)], node.nodeType, loc);
		},
		_ => {
			// PromiseFinally — wildcard is safe: outer dispatch restricts to these three.
			const typedFn = futureFinallyFnForInner(innerType);
			const finallyArgs: Node[] = [me.object];
			for (const a of cd.arguments) { finallyArgs.push(a); }
			return mkTypedCall(typedFn !== "" ? typedFn : "msFutureFinally", finallyArgs, node.nodeType, loc);
		},
	};
}

function lowerPromiseResolve(node: Node, loc: SourceLocation): Node {
	const cd = node.data as CallExprData;
	if (cd.arguments.length < 1) return node;
	const boxed = boxValueForFuture(cd.arguments[0], loc);
	const resolveCall = makeCall(makeIdent("msPromiseResolve", loc), [boxed], loc);
	resolveCall.nodeType = node.nodeType;
	return resolveCall;
}

// spawn(fn) lowering:
// - String returns → msSpawnInto(msFutureCreateInline<T>(), fn). Worker memcpys the
//   boxed result into the typed-inline fut, frees the box.
// - Everything else → msSpawn(fn). The worker stores the closure's boxed void*
//   result in the future slot: primitive bits directly, struct/tuple/GI as the
//   heap-box pointer — matching boxedInFuture readers (msUnboxStruct).
// Each call's nodeType is its true result type (Promise<T>). Codegen extracts T via
// awaitedType — no more abuse of nodeType as a sizeof-hint.
function lowerPromiseSpawn(node: Node, loc: SourceLocation): Node {
	const cd = node.data as CallExprData;
	const innerType = awaitedType(node.nodeType);
	if (inlineInFuture(innerType)) {
		const futAlloc = makeCall(makeIdent("msFutureCreateInline", loc), [], loc);
		futAlloc.nodeType = node.nodeType;  // Promise<T>
		const spawnInto = makeCall(makeIdent("msSpawnInto", loc), [futAlloc, cd.arguments[0]], loc);
		spawnInto.nodeType = node.nodeType;  // Promise<T>
		return spawnInto;
	}
	const spawnCall = makeCall(makeIdent("msSpawn", loc), cd.arguments, loc);
	spawnCall.nodeType = node.nodeType;
	return spawnCall;
}

// Promise.all(Promise<T>[]) — dispatch to typed variant per inner T.
// Post typed-inline-storage refactor, the generic msPromiseAll reads f->value
// as void* which truncates any struct value (msString, tuples, user structs).
// msPromiseAllFor_msFuture_<T> uses the typed struct cast + per-T copy and
// builds the proper T[] result (msNumberArray / msStringArray / T##Array…).
// Only void-returning promises fall through to the generic path (no value to
// copy). Unknown inner types also fall through but will read garbage — caller's
// responsibility to type the argument correctly.
function lowerPromiseAll(node: Node, loc: SourceLocation): Node {
	const cd = node.data as CallExprData;
	if (cd.arguments.length < 1 || cd.arguments[0].nodeType === null) return node;
	const argArrType = cd.arguments[0].nodeType;
	// argArrType is Array<Promise<T>>; typeReturn is Promise<T>; awaitedType is T.
	const elementPromise = argArrType.typeReturn;
	const innerT = elementPromise !== null ? awaitedType(elementPromise) : null;
	const typedFn = promiseAllFnForInner(innerT);
	if (typedFn === "") return node;  // void-returning: falls through to generic msPromiseAll
	const typedCall = makeCall(makeIdent(typedFn, loc), cd.arguments, loc);
	typedCall.nodeType = node.nodeType;
	return typedCall;
}

// waitFor(fut) — dispatch based on return type:
//   void            → msWaitFor(fut)                (block, discard result)
//   inlineInFuture  → msWaitForStruct(fut)          (typed inline read — String)
//   everything else → unboxVoidPtrToTyped(msWaitFor) (primitive bits / heap box)
function lowerWaitFor(node: Node, loc: SourceLocation): Node {
	const cd = node.data as CallExprData;
	const retType = node.nodeType;
	if (retType === null || retType.kind === TypeKind.Void) {
		return makeCall(makeIdent("msWaitFor", loc), cd.arguments, loc);
	}
	if (inlineInFuture(retType)) {
		const waitStruct = makeCall(makeIdent("msWaitForStruct", loc), cd.arguments, loc);
		waitStruct.nodeType = retType;
		return waitStruct;
	}
	// Everything else (primitive boxed in void*, Array/Ref heap-boxed): wait
	// then dispatch through the shared unbox helper.
	const waitCall = makeCall(makeIdent("msWaitFor", loc), cd.arguments, loc);
	return unboxVoidPtrToTyped(waitCall, retType, loc);
}

// ===== Public dispatch =====

// Dispatch a builtin Promise/WaitFor call. Returns the rewritten Node if
// `builtinKind` belongs to the Promise family, otherwise returns null to
// signal "not my concern, keep looking".
// Caller pattern (builtinLower.ms):
//   const promiseRewrite = tryLowerPromiseBuiltin(node, builtinKind, ctx);
//   if (promiseRewrite !== null) return promiseRewrite;
export function tryLowerPromiseBuiltin(node: Node, builtinKind: string, ctx: TransformContext): Node {
	const loc = node.location;
	if (builtinKind === "PromiseThen" || builtinKind === "PromiseCatch" || builtinKind === "PromiseFinally") {
		return lowerPromiseThenCatchFinally(node, builtinKind, loc);
	}
	if (builtinKind === "PromiseResolve") return lowerPromiseResolve(node, loc);
	if (builtinKind === "PromiseSpawn") return lowerPromiseSpawn(node, loc);
	if (builtinKind === "PromiseAll") return lowerPromiseAll(node, loc);
	if (builtinKind === "WaitFor") return lowerWaitFor(node, loc);
	return null as unknown as Node;
}

// Rewrite `new Promise(executor)` → `msPromiseNew(executor)`. Invoked by
// builtinLower's main walker for NewExpr nodes — only fires when the target
// type is awaitable (Promise<T>).
export function lowerNewPromise(node: Node): Node {
	if (node.nodeType !== null && isAwaitable(node.nodeType)) {
		const d = node.data as NewExprData;
		if (d.newArguments.length === 1) {
			const loc = node.location;
			const newCall = makeCall(makeIdent("msPromiseNew", loc), d.newArguments, loc);
			newCall.nodeType = node.nodeType;
			return newCall;
		}
	}
	return node;
}
