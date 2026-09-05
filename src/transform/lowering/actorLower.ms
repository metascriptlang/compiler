// Actor Lowering — transform ActorDecl into async actor infrastructure
//
// After this pass, zero ActorDecl nodes remain. DRC and codegen see:
// - ClassDecl (state struct with pid field)
// - FunctionDecl _impl handlers (original method bodies, called by dispatch)
// - FunctionDecl proxies (enqueue message via msActorSend — what callers invoke)
// - FunctionDecl dispatch (switches on msg kind, calls _impl handlers)
// - @include("runtime/actor/actor.h") injected for C compilation

import { Node, NodeKind, NodeFlag, SourceLocation, DeclKind, Type, TypeKind,
	ActorDeclData, MethodDeclData, ConstructorDeclData,
	DecoratedDeclData, ExportDeclData, ProgramData, NewExprData,
	IdentifierData, VariableDeclData, FunctionDeclData, IfStmtData,
	WhileStmtData, ForOfStmtData, ForStmtData, BlockStmtData,
	DoWhileStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	ExprStmtData, ReturnStmtData, TestDeclData,
	Symbol, SymbolKind, SymbolState, createNode } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { canFormAcycle } from "../cycles";
import { containsExprKind, replaceInExpr } from "../walker";
import { makeSymbol, setFlag, SymbolFlag } from "../../checker/symbol";
import {
	syntheticToken, makeIdent, makeIdentResolved, makeCall, makeExprStmt, makeReturn,
	makeVarDecl, makeMember, makeNumber, makeNull, makeBlock, makeBinary,
	isValueLayoutType, makeHiddenAddr, makeTryFinally,
} from "../util";
import { voidType, noneType, createFunction, createPromise, createRef, createStruct, createPtr, createPrimitive, getSysType, isStructType, isAtomicRef, instantiateGenericBody, typeDisplayName } from "../../checker/types";
import { getGenericDecl } from "../../parser/context";

// msMessage.data[56] holds 7 pointer-sized slots (56 / 8 on 64-bit).
const MS_MSG_MAX_ARGS = 7;
// void* type for HiddenStdConv casts in actor message packing/completion.
const VOID_PTR: Type = createPtr(createPrimitive(TypeKind.Void));

// Built-in GIs (Result/Promise/Iterator) have typeReturn=null after
// createGenericInstance — populate body so isValueLayoutType sees the Union.
function ensureGIBody(t: Type | null): void {
	if (t === null) return;
	if (t.kind !== TypeKind.GenericInstance) return;
	if (t.typeReturn !== null) return;
	if (t.typeName === "") return;
	const params = getGenericDecl(t.typeName);
	if (params !== "") instantiateGenericBody(t, params);
}

function typeMsgKind(t: Type | null): string {
	if (t === null) return "ptr";
	ensureGIBody(t);
	if (isValueLayoutType(t)) return "struct";
	if (t.kind === TypeKind.Distinct || t.kind === TypeKind.Alias) return typeMsgKind(t.typeReturn);
	const result = match (t.kind) {
		TypeKind.String => "string",
		TypeKind.Array => "array",
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "double",
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32
			| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32
			| TypeKind.Enum => "int32",
		TypeKind.Int64 | TypeKind.Uint64 => "int64",
		TypeKind.Boolean => "bool",
		TypeKind.Function | TypeKind.Span | TypeKind.Union => "struct",
		TypeKind.Ref | TypeKind.Ptr | TypeKind.CString => "ptr",
		_ => "",
	};
	if (result === "") throw "actor: unsupported TypeKind " + typeDisplayName(t);
	return result;
}

function paramMsgKind(paramTypes: Type[], idx: number): string {
	if (paramTypes === null || idx >= paramTypes.length) return "ptr";
	return typeMsgKind(paramTypes[idx]);
}

// "array"/"struct" not listed — packArgsIntoMsg heap-boxes them upstream.
function msgSetterName(mk: string): string {
	return match (mk) {
		"double" => "msMsgSetDouble",
		"int32"  => "msMsgSetInt32",
		"int64"  => "msMsgSetInt64",
		"bool"   => "msMsgSetBool",
		"string" => "msMsgSetString",
		_ => "msMsgSetPtr",
	};
}

function msgGetterName(mk: string): string {
	return match (mk) {
		"double" => "msMsgGetDouble",
		"int32"  => "msMsgGetInt32",
		"int64"  => "msMsgGetInt64",
		"bool"   => "msMsgGetBool",
		"string" => "msMsgGetString",
		_ => "msMsgGetPtr",
	};
}

function msgCompleteName(mk: string): string {
	return match (mk) {
		"double" => "msMsgCompleteDouble",
		"int32"  => "msMsgCompleteInt32",
		"int64"  => "msMsgCompleteInt64",
		"bool"   => "msMsgCompleteBool",
		"string" => "msMsgCompleteString",
		"array" | "struct" => "msMsgCompletePtr",
		_ => "msMsgCompletePtr",
	};
}

function futureChainFn(mk: string): string {
	return match (mk) {
		"double" => "msFutureChain_double",
		"int32"  => "msFutureChain_int32",
		"int64"  => "msFutureChain_int64",
		"bool"   => "msFutureChain_bool",
		"string" => "msFutureChain_msString",
		"ptr"    => "msFutureChain_ptr",
		_ => "msFutureChain",
	};
}

function futureChainFnForReturn(retType: Type | null): string {
	if (retType === null) return "msFutureChain";
	const inner = retType.typeReturn !== null ? retType.typeReturn : retType;
	return futureChainFn(typeMsgKind(inner));
}

// "string" = 2 slots (16B inlined); "array"/"struct" = 1 slot (heap-boxed).
function paramSlotWidth(paramTypes: Type[], idx: int32): int32 {
	const mk = paramMsgKind(paramTypes, idx);
	return mk === "string" ? 2 : 1;
}

// Force T* on actor proxy/impl for value-layout params so msSinkBoxStruct's
// memset reaches caller's local (not just proxy's copy) — prevents double-free.
function markValueLayoutParamsAsMutated(sym: Symbol, paramTypes: Type[]): void {
	if (sym === null) return;
	let bits: int32 = sym.mutatedParams;
	const limit: number = paramTypes.length < 32 ? paramTypes.length : 32;
	for (let i = 0; i < limit; i = i + 1) {
		const t = paramTypes[i];
		if (t === null) continue;
		if (typeMsgKind(t) === "struct") {
			bits = (bits | (1 << (i as int32))) as int32;
		}
	}
	sym.mutatedParams = bits;
}

function totalSlotCount(params: string[], paramTypes: Type[]): number {
	let total = 0;
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		total = total + paramSlotWidth(paramTypes, ai);
	}
	return total;
}

// Value-layout PARAMs ("struct"/"array") heap-boxed via msSinkBoxStruct → msMsgSetPtr.
function packArgsIntoMsg(stmts: Node[], msgSym: Symbol, params: string[], paramTypes: Type[], loc: SourceLocation): void {
	let slot = 0;
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		const mk = paramMsgKind(paramTypes, ai);
		let valueArg: Node;
		let setter: string;
		if (mk === "array" || mk === "struct") {
			const paramIdent = makeIdent(params[ai], loc);
			paramIdent.nodeType = paramTypes[ai];
			const boxCall = makeCall(makeIdent("msSinkBoxStruct", loc), [paramIdent], loc);
			boxCall.nodeType = VOID_PTR;
			valueArg = boxCall;
			setter = "msMsgSetPtr";
		} else {
			valueArg = makeIdent(params[ai], loc);
			setter = msgSetterName(mk);
			// SHARE boundary rc (PARALOCK Amendment I): Arc<T> args pack with an
			// atomic incref; the _impl handler releases in its finally.
			if (mk === "ptr" && paramTypes[ai] !== null && isAtomicRef(paramTypes[ai])) {
				setter = "msMsgSetPtrShared";
			}
		}
		stmts.push(makeExprStmt(makeCall(makeIdent(setter, loc), [
			makeIdentResolved(msgSym, loc),
			makeNumber(slot, loc),
			valueArg,
		], loc), loc));
		slot = slot + paramSlotWidth(paramTypes, ai);
	}
}

function buildSendProxy(kind: number, params: string[], paramTypes: Type[], ctx: TransformContext, loc: SourceLocation): Node {
	const msgSym = freshTempSym(ctx, "amsg", VOID_PTR);
	const slotCount = totalSlotCount(params, paramTypes);
	const msgAlloc = makeCall(makeIdent("msMsgAllocSized", loc), [
		makeNumber(kind, loc),
		makeNull(loc),
		makeNumber(slotCount, loc),
	], loc);
	msgAlloc.nodeType = VOID_PTR;
	const msgDecl = makeVarDecl(msgSym.name, msgAlloc, DeclKind.Const, loc);
	msgDecl.resolvedSym = msgSym;
	msgDecl.nodeType = VOID_PTR;
	const stmts: Node[] = [msgDecl];
	packArgsIntoMsg(stmts, msgSym, params, paramTypes, loc);
	const thisPid = makeMember(makeIdent("this", loc), "pid", loc);
	thisPid.nodeType = getSysType(TypeKind.Int64);
	const actorPtr = makeCall(makeIdent("msActorFromPid", loc), [thisPid], loc);
	const sendCall = makeCall(makeIdent("msActorSend", loc), [actorPtr, makeIdentResolved(msgSym, loc)], loc);
	stmts.push(makeExprStmt(sendCall, loc));
	return makeBlock(stmts, loc);
}

// ===== Build proxy body for a T-returning method (call semantics) =====

function buildCallProxy(kind: number, params: string[], paramTypes: Type[], retType: Type, ctx: TransformContext, loc: SourceLocation): Node {
	const futSym = freshTempSym(ctx, "afut", VOID_PTR);
	const msgSym = freshTempSym(ctx, "amsg", VOID_PTR);
	// Only String needs typed-sized future (msMsgCompleteString writes the
	// 16-byte payload inline). Struct/Tuple/value-GI returns are heap-boxed
	// in the dispatch body, so they fit the generic 8-byte msFutureCreate.
	const isStringReturn = retType !== null && retType.kind === TypeKind.String;
	let futCreate: Node;
	if (isStringReturn) {
		futCreate = makeCall(makeIdent("msFutureCreateInline", loc), [], loc);
		// nodeType MUST be Promise<T> (not raw T) so codegen's intercept can
		// extract T via awaitedType — mirrors asyncBridge.makeRetFutAlloc.
		futCreate.nodeType = createPromise(retType);
	} else {
		futCreate = makeCall(makeIdent("msFutureCreate", loc), [], loc);
		futCreate.nodeType = createPromise(retType);
	}
	const futDecl = makeVarDecl(futSym.name, futCreate, DeclKind.Const, loc);
	futDecl.resolvedSym = futSym;
	futDecl.nodeType = VOID_PTR;
	const slotCount = totalSlotCount(params, paramTypes);
	const msgAlloc = makeCall(makeIdent("msMsgAllocSized", loc), [
		makeNumber(kind, loc),
		makeIdentResolved(futSym, loc),
		makeNumber(slotCount, loc),
	], loc);
	msgAlloc.nodeType = VOID_PTR;
	const msgDecl = makeVarDecl(msgSym.name, msgAlloc, DeclKind.Const, loc);
	msgDecl.resolvedSym = msgSym;
	msgDecl.nodeType = VOID_PTR;
	const stmts: Node[] = [futDecl, msgDecl];
	packArgsIntoMsg(stmts, msgSym, params, paramTypes, loc);
	const thisPid2 = makeMember(makeIdent("this", loc), "pid", loc);
	thisPid2.nodeType = getSysType(TypeKind.Int64);
	const actorPtr2 = makeCall(makeIdent("msActorFromPid", loc), [thisPid2], loc);
	const sendCall = makeCall(makeIdent("msActorSend", loc), [actorPtr2, makeIdentResolved(msgSym, loc)], loc);
	stmts.push(makeExprStmt(sendCall, loc));
	const retFut = makeReturn(makeIdentResolved(futSym, loc), loc);
	stmts.push(retFut);
	return makeBlock(stmts, loc);
}

// Resolved ident needed so ensureCrossModuleProto reads implSym.mutatedParams
// for correct forward-decl signatures (T* vs T for value-layout params).
function findImplSym(result: Node[], implName: string): Symbol {
	for (const n of result) {
		let inner = n;
		if (n.kind === NodeKind.DecoratedDecl) {
			const dd = n.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) inner = dd.decoratedNode;
		}
		if (inner.kind === NodeKind.FunctionDecl && inner.resolvedSym !== null
				&& inner.resolvedSym.nativeName === implName) {
			return inner.resolvedSym;
		}
	}
	return null as unknown as Symbol;
}

function buildDispatchBody(methods: Node[], actorName: string, loc: SourceLocation, result: Node[]): Node {
	const stmts: Node[] = [];
	// Cast void* this to actor's Ref type via HiddenStdConv (no C cast emitted — just type annotation).
	// This tells codegen the argument is already a pointer, preventing &() struct promotion.
	const actorRefType = createRef(createStruct(actorName, [], [], true));
	const thisIdent = makeIdent("this", loc);
	thisIdent.nodeType = createPtr(voidType());
	const castThis = createNode(NodeKind.HiddenStdConv, {
		convExpr: thisIdent,
		convType: actorRefType,
	}, syntheticToken(loc));
	castThis.nodeType = actorRefType;
	const selfDecl = makeVarDecl("_self", castThis, DeclKind.Const, loc);
	selfDecl.nodeType = actorRefType;
	stmts.push(selfDecl);

	let msgKind = 0;
	for (const m of methods) {
		if (m.kind !== NodeKind.MethodDecl) continue;
		const md = m.data as MethodDeclData;
		const isVoid = md.methodReturnType === "" || md.methodReturnType === "void";
		// Condition: msMsgKind(_dmsg) === N
		const kindCall = makeCall(makeIdent("msMsgKind", loc), [makeIdent("_dmsg", loc)], loc);
		const cond = makeBinary(kindCall, "===", makeNumber(msgKind, loc), loc);
		const selfRef = makeIdent("_self", loc);
		selfRef.nodeType = actorRefType;
		// Build handler call args: _self + unpacked args from msg (slot-aware)
		const mParamTypes = m.nodeType !== null ? m.nodeType.typeChildren : [];
		const handlerArgs: Node[] = [selfRef];
		let dSlot = 0;
		for (let ai = 1; ai < md.methodParams.length; ai = ai + 1) {
			const mk = paramMsgKind(mParamTypes, ai);
			if (mk === "array" || mk === "struct") {
				// "struct" needs explicit HiddenAddr (ccgIntroducedPtr=false for small structs);
				// "array" gets & via shimCallArg (ccgIntroducedPtr=true unconditionally).
				const getPtrCall = makeCall(makeIdent("msMsgGetPtr", loc), [
					makeIdent("_dmsg", loc),
					makeNumber(dSlot, loc),
				], loc);
				const unboxCall = makeCall(makeIdent("msUnboxStruct", loc), [getPtrCall], loc);
				unboxCall.nodeType = mParamTypes[ai];
				if (mk === "struct") {
					handlerArgs.push(makeHiddenAddr(unboxCall, loc));
				} else {
					handlerArgs.push(unboxCall);
				}
			} else {
				const getter = msgGetterName(mk);
				const getCall = makeCall(makeIdent(getter, loc), [
					makeIdent("_dmsg", loc),
					makeNumber(dSlot, loc),
				], loc);
				if (mk === "ptr") {
					getCall.nodeType = VOID_PTR;
				}
				handlerArgs.push(getCall);
			}
			dSlot = dSlot + paramSlotWidth(mParamTypes, ai);
		}
		const implName = actorName + "_" + md.methodName + "_impl";
		const implSym = findImplSym(result, implName);
		// Callee resolved (forward-decl correctness) but CallExpr.resolvedSym=null
		// to avoid emitNativeCall path which skips ccgIntroducedPtr promotion.
		const implIdent = implSym !== null ? makeIdentResolved(implSym, loc) : makeIdent(implName, loc);
		const handlerCall = makeCall(implIdent, handlerArgs, loc);
		handlerCall.resolvedSym = null;
		let body: Node;
		const isSuspending = md.methodFlags === "async_actor";
		if (isSuspending) {
			// Phase 5: async _impl returns msFuture*. Suspend actor, chain reply.
			const bodyStmts: Node[] = [];
			const implFutDecl = makeVarDecl("_implFut", handlerCall, DeclKind.Const, loc);
			implFutDecl.nodeType = VOID_PTR;
			bodyStmts.push(implFutDecl);
			let replyFutArg: Node = makeNull(loc);
			if (!isVoid) {
				// CALL: store reply future, chain _impl's future → reply future.
				// Select typed chain variant based on method's declared return type
				// so msString (16B) and other typed values are copied correctly.
				const chainFn = futureChainFnForReturn(m.nodeType);
				const futAccessCall = makeCall(makeIdent("msMsgReplyFuture", loc), [makeIdent("_dmsg", loc)], loc);
				const replyDecl = makeVarDecl("_replyFut", futAccessCall, DeclKind.Const, loc);
				replyDecl.nodeType = VOID_PTR;
				bodyStmts.push(replyDecl);
				bodyStmts.push(makeExprStmt(
					makeCall(makeIdent(chainFn, loc), [makeIdent("_implFut", loc), makeIdent("_replyFut", loc)], loc), loc));
				replyFutArg = makeIdent("_replyFut", loc);
			}
			// Derive msActor* from _self.pid, pass reply future for R1 stop
			const selfPid = makeMember(makeIdent("_self", loc), "pid", loc);
			selfPid.nodeType = getSysType(TypeKind.Int64);
			const actorPtr = makeCall(makeIdent("msActorFromPid", loc), [
				selfPid,
			], loc);
			bodyStmts.push(makeExprStmt(
				makeCall(makeIdent("msActorSuspend", loc), [actorPtr, makeIdent("_implFut", loc), replyFutArg], loc), loc));
			body = makeBlock(bodyStmts, loc);
		} else if (isVoid) {
			body = makeBlock([makeExprStmt(handlerCall, loc)], loc);
		} else {
			const retType = m.nodeType !== null && m.nodeType.typeReturn !== null ? m.nodeType.typeReturn : null;
			const retMk = typeMsgKind(retType);
			const completeFn = msgCompleteName(retMk);
			const resultDecl = makeVarDecl("_result", handlerCall, DeclKind.Const, loc);
			const futAccessCall = makeCall(makeIdent("msMsgReplyFuture", loc), [makeIdent("_dmsg", loc)], loc);
			if ((retMk === "array" || retMk === "struct") && retType !== null) {
				// Heap-box: msSinkBoxStruct → msMsgCompletePtr → await side's
				// msUnboxStruct unboxes. Reply future stays a uniform 8-byte slot.
				// boxCall.nodeType = void* per PARALOCK I13 (asyncBridge canonical).
				const boxCall = makeCall(makeIdent("msSinkBoxStruct", loc), [makeIdent("_result", loc)], loc);
				boxCall.nodeType = VOID_PTR;
				const boxDecl = makeVarDecl("_boxed", boxCall, DeclKind.Const, loc);
				boxDecl.nodeType = VOID_PTR;
				const completeCall = makeCall(makeIdent(completeFn, loc), [futAccessCall, makeIdent("_boxed", loc)], loc);
				body = makeBlock([resultDecl, boxDecl, makeExprStmt(completeCall, loc)], loc);
			} else {
				const completeCall = makeCall(makeIdent(completeFn, loc), [futAccessCall, makeIdent("_result", loc)], loc);
				body = makeBlock([resultDecl, makeExprStmt(completeCall, loc)], loc);
			}
		}
		const emptyBlock = makeBlock([], loc);
		const ifNode = createNode(NodeKind.IfStmt, {
			condition: cond,
			consequent: body,
			alternate: emptyBlock,
		}, syntheticToken(loc));
		stmts.push(ifNode);
		msgKind = msgKind + 1;
	}
	return makeBlock(stmts, loc);
}

// ===== Emit state struct (ClassDecl with pid field) =====

function emitActorStruct(node: Node, d: ActorDeclData, loc: SourceLocation): Node {
	const structMembers: Node[] = [];
	const pidProp = createNode(NodeKind.PropertyDecl, {
		propName: "pid",
		propType: "int64",
		propIsStatic: false,
		propIsReadonly: true,
		propVisibility: "",
		propInitializer: null as unknown as Node,
	}, syntheticToken(loc));
	pidProp.nodeType = getSysType(TypeKind.Int64);
	structMembers.push(pidProp);
	for (const member of d.actorBody) {
		let m = member;
		if (m.kind === NodeKind.DecoratedDecl) {
			const dd = m.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) m = dd.decoratedNode;
		}
		if (m.kind === NodeKind.PropertyDecl) {
			structMembers.push(member);
		}
		// Include constructor in class but with empty body (allocation only).
		// The real constructor body runs after pid wiring as a standalone function.
		if (m.kind === NodeKind.ConstructorDecl) {
			const cd = m.data as ConstructorDeclData;
			const emptyCtor = createNode(NodeKind.ConstructorDecl, {
				ctorParams: cd.ctorParams,
				ctorParamTypes: cd.ctorParamTypes,
				ctorBody: makeBlock([], loc),
				ctorDefaults: cd.ctorDefaults,
			}, syntheticToken(loc));
			emptyCtor.resolvedSym = m.resolvedSym;
			emptyCtor.nodeType = m.nodeType;
			structMembers.push(emptyCtor);
		}
	}
	const classNode = createNode(NodeKind.ClassDecl, {
		className: d.actorName,
		classExtends: "",
		classBody: structMembers,
		nameLocation: d.nameLocation,
	}, syntheticToken(loc));
	classNode.resolvedSym = node.resolvedSym;
	classNode.nodeType = node.nodeType;
	if (node.resolvedSym !== null) {
		node.resolvedSym.declNode = classNode;
	}
	return classNode;
}

// ===== Emit _impl handlers + proxy functions for each method =====

// Boundary rc release (PARALOCK Amendment I). Two verbs land here:
//
//   SHARE — Arc<T>, any method. packArgsIntoMsg's msMsgSetPtrShared took the
//   message's atomic incref; the _impl returns it exactly once.
//
//   MOVE — a plain ref into a SEND-class (void) method. The proxy stores the
//   pointer raw (no incref) because the caller already gave up its reference:
//   the analyzer classifies the arg Consumed and emits wasMoved with no
//   destroy. Nothing downstream owned it — dispatch hands msMsgGetPtr straight
//   to the _impl and msMsgFree cannot see which slots are refs — so the _impl
//   is the owner and must release. Unconditional release is sound because the
//   checker rejects a plain ref at a SEND-class call unless it is `move`
//   (sendable.ms, PARALOCK I21), and a void method cannot be awaited, so no
//   BORROW shape ever reaches a void _impl.
//
// Non-void methods keep BORROW: their plain-ref args stay alive on the parked
// sender's frame and must NOT be released here.
//
// try/finally (not a trailing statement) so early returns AND async suspension
// (finally rides the async body's completion) both release. Applies to
// message-dispatched methods only — lifecycle hooks never cross the boundary.
function wrapImplBodyWithShareRelease(body: Node, params: string[], paramTypes: Type[] | null, isVoid: boolean, ctx: TransformContext, loc: SourceLocation): Node {
	if (paramTypes === null) return body;
	const releases: Node[] = [];
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		const t = ai < paramTypes.length ? paramTypes[ai] : null;
		if (t === null || t.kind !== TypeKind.Ref) continue;
		// Actors are DRC-exempt (classify.ms Ref arm): the actor runtime owns
		// their lifetime, the caller never gave up a count (the arg is not
		// Consumed), and nothing increfed on the way in. Releasing one here
		// would free a live actor out from under its own mailbox.
		if (t.sym !== null && t.sym.symbolKind === SymbolKind.Actor) continue;
		let releaseFn = "";
		if (isAtomicRef(t)) {
			releaseFn = "msAtomicDecref";
		} else if (isVoid) {
			// Mirror the analyzer's own choice for this type (classify.ms Ref arm)
			// so an ORC build still unregisters a cycle-capable pointee.
			releaseFn = canFormAcycle(t, ctx.cyclicCache, ctx.acyclicCache) ? "msDecrefCyclic" : "msDecref";
		} else {
			continue;
		}
		const argIdent = makeIdent(params[ai], loc);
		argIdent.nodeType = t;
		releases.push(makeExprStmt(makeCall(makeIdent(releaseFn, loc), [argIdent], loc), loc));
	}
	if (releases.length === 0) return body;
	// Wrap the try in a Block: asyncBridge's rewriteAsyncFnBody requires the
	// async impl's body to be a BlockStmt (a bare TryCatchStmt body threw
	// "un-normalized"). Block-wrapping is semantically inert for the sync path.
	const boundaryRelease = makeTryFinally(body, makeBlock(releases, loc), loc);
	return makeBlock([boundaryRelease], loc);
}

function emitActorMethods(d: ActorDeclData, name: string, ctx: TransformContext, loc: SourceLocation, result: Node[]): void {
	let msgKind = 0;
	for (const member of d.actorBody) {
		let m = member;
		let decorators: Node[] = [];
		if (m.kind === NodeKind.DecoratedDecl) {
			const dd = m.data as DecoratedDeclData;
			decorators = dd.decorators;
			if (dd.decoratedNode !== null) m = dd.decoratedNode;
		}
		if (m.kind === NodeKind.MethodDecl) {
			const md = m.data as MethodDeclData;
			// Lifecycle hooks — NOT message-dispatched. Emit as standalone _impl.
			if (md.methodName === "onTerminate" || md.methodName === "onExit" || md.methodName === "onDown" || md.methodName === "onIdle") {
				const implNativeName = name + "_" + md.methodName + "_impl";
				const implNode = createNode(NodeKind.FunctionDecl, {
					fnName: implNativeName,
					params: md.methodParams,
					fnParamTypes: md.methodParamTypes,
					fnBody: md.methodBody,
					fnFlags: "",
					fnReturnType: "void",
					fnDefaults: [],
					nativeName: implNativeName,
					nameLocation: md.nameLocation,
				}, syntheticToken(loc));
				implNode.nodeType = m.nodeType;
				implNode.typeExprs = m.typeExprs;
				implNode.paramLocations = m.paramLocations;
				const implSym = makeSymbol(implNativeName, SymbolKind.Function, m.nodeType !== null ? m.nodeType : noneType(), false);
				implSym.nativeName = implNativeName;
				implSym.state = SymbolState.Checked;
				implNode.resolvedSym = implSym;
				result.push(implNode);
				continue;
			}
			const isVoid = md.methodReturnType === "" || md.methodReturnType === "void";
			// Guard: data[56] inline buffer fits 7 args max
			const argCount = md.methodParams.length - 1;
			if (argCount > MS_MSG_MAX_ARGS) {
				console.log(`warning: actor method '${name}.${md.methodName}' has ${argCount} args (max ${MS_MSG_MAX_ARGS} for inline message buffer)`);
			}

			// _impl handler: original body, nativeName for predictable C name.
			// Phase 5: skip if already extracted by lowerActorPre (sentinel "async_actor").
			const implNativeName = name + "_" + md.methodName + "_impl";
			if (md.methodFlags !== "async_actor") {
				const implNode = createNode(NodeKind.FunctionDecl, {
					fnName: implNativeName,
					params: md.methodParams,
					fnParamTypes: md.methodParamTypes,
					fnBody: wrapImplBodyWithShareRelease(md.methodBody, md.methodParams, m.nodeType !== null ? m.nodeType.typeChildren : null, isVoid, ctx, loc),
					fnFlags: md.methodFlags,
					fnReturnType: md.methodReturnType,
					fnDefaults: [],
					nativeName: implNativeName,
					nameLocation: md.nameLocation,
				}, syntheticToken(loc));
				implNode.nodeType = m.nodeType;
				implNode.typeExprs = m.typeExprs;
				implNode.paramLocations = m.paramLocations;
				const implSym = makeSymbol(implNativeName, SymbolKind.Function, m.nodeType !== null ? m.nodeType : noneType(), false);
				implSym.nativeName = implNativeName;
				implSym.state = SymbolState.Checked;
				implNode.resolvedSym = implSym;
				if (m.nodeType !== null) markValueLayoutParamsAsMutated(implSym, m.nodeType.typeChildren);
				result.push(implNode);
			}

			// Proxy: enqueues message (what extensionMethodLower resolves to)
			const methodParamTypes = m.nodeType !== null ? m.nodeType.typeChildren : [];
			const methodRetType = m.nodeType !== null && m.nodeType.typeReturn !== null ? m.nodeType.typeReturn : voidType();
			const proxyBody = isVoid
				? buildSendProxy(msgKind, md.methodParams, methodParamTypes, ctx, loc)
				: buildCallProxy(msgKind, md.methodParams, methodParamTypes, methodRetType, ctx, loc);
			const proxyParamTypes = m.nodeType !== null ? m.nodeType.typeChildren : [];
			// Proxy returns the reply Promise<T>, not T directly. The user-visible
			// type at the call site MUST be Promise<T> so:
			//   1. await can unwrap correctly (looks for awaitable)
			//   2. C codegen does NOT apply NRVO at the call site (Promise<T> is
			//      a pointer to msFuture_<T>, fits in void*). Previously this was
			//      noneType() which caused the C compiler to emit out-param
			//      calling convention for value-layout T (Result/struct/tuple),
			//      but the proxy's actual C signature returns void* — argument
			//      count mismatch at the call site.
			const proxyRetType = isVoid ? voidType()
				: methodRetType !== null ? createPromise(methodRetType) : noneType();
			const proxyFnType = createFunction(proxyParamTypes, md.methodParams, proxyRetType);
			const proxyNode = createNode(NodeKind.FunctionDecl, {
				fnName: name + "_" + md.methodName,
				params: md.methodParams,
				fnParamTypes: md.methodParamTypes,
				fnBody: proxyBody,
				fnFlags: md.methodFlags,
				fnReturnType: isVoid ? "void" : "unknown",
				fnDefaults: [],
				nativeName: "",
				nameLocation: md.nameLocation,
			}, syntheticToken(loc));
			proxyNode.resolvedSym = m.resolvedSym;
			proxyNode.nodeType = proxyFnType;
			// Sync sym to proxy signature so call sites see Promise<T> (no
			// NRVO out-param). Without this, codegen emits a NRVO call against
			// the proxy's actual void* return — argument-count mismatch at C
			// compile for any value-layout T.
			//
			// CAUTION — only sym.symbolType mutation in transform/analyzer.
			// If a later pass needs the ORIGINAL `T getR()` shape, capture it
			// BEFORE this point — sym now refers to the proxy.
			if (m.resolvedSym !== null) {
				m.resolvedSym.symbolType = proxyFnType;
				markValueLayoutParamsAsMutated(m.resolvedSym, proxyParamTypes);
				// The analyzer reads this to classify UNPARKED calls to the proxy as
				// SEND-class handoffs (plain-ref args consumed into the message);
				// parked calls carry NodeFlag.AwaitParked instead and stay borrows.
				setFlag(m.resolvedSym, SymbolFlag.ActorProxy);
			}
			proxyNode.typeExprs = m.typeExprs;
			proxyNode.paramLocations = m.paramLocations;
			if (decorators.length > 0) {
				result.push(createNode(NodeKind.DecoratedDecl, {
					decorators,
					decoratedNode: proxyNode,
				}, syntheticToken(loc)));
			} else {
				result.push(proxyNode);
			}
			msgKind = msgKind + 1;
		}
		if (m.kind === NodeKind.ConstructorDecl) {
			const cd = m.data as ConstructorDeclData;
			// Prepend 'this' param (constructors don't have it, but the standalone function needs it)
			const ctorParams = ["this"];
			for (const p of cd.ctorParams) ctorParams.push(p);
			const ctorParamTypes = [name];
			for (const t of cd.ctorParamTypes) ctorParamTypes.push(t);
			const fnNode = createNode(NodeKind.FunctionDecl, {
				fnName: name + "_constructor",
				params: ctorParams,
				fnParamTypes: ctorParamTypes,
				fnBody: cd.ctorBody,
				fnFlags: "",
				fnReturnType: "void",
				fnDefaults: cd.ctorDefaults,
				nativeName: name + "_constructor",
				nameLocation: loc,
			}, syntheticToken(loc));
			// Build proper Function type with actor Ref as first param (codegen needs it for Watchdog* this)
			const actorRefType = createRef(createStruct(name, [], [], true));
			const ctorTypeChildren: Type[] = [actorRefType];
			if (m.nodeType !== null && m.nodeType.typeChildren !== null) {
				for (const tc of m.nodeType.typeChildren) ctorTypeChildren.push(tc);
			}
			fnNode.nodeType = createFunction(ctorTypeChildren, ctorParams, voidType());
			const ctorSym = makeSymbol(name + "_constructor", SymbolKind.Function, fnNode.nodeType, false);
			ctorSym.nativeName = name + "_constructor";
			ctorSym.state = SymbolState.Checked;
			fnNode.resolvedSym = ctorSym;
			fnNode.typeExprs = m.typeExprs;
			fnNode.paramLocations = m.paramLocations;
			result.push(fnNode);
		}
	}
}

// ===== Emit dispatch function =====

function emitActorDispatch(d: ActorDeclData, name: string, methods: Node[], loc: SourceLocation, result: Node[]): Node {
	const dispatchNativeName = name + "_dispatch";
	const dispatchBody = buildDispatchBody(methods, name, loc, result);
	const fnNode = createNode(NodeKind.FunctionDecl, {
		fnName: dispatchNativeName,
		params: ["this", "_dmsg"],
		fnParamTypes: [name, "void"],
		fnBody: dispatchBody,
		fnFlags: "",
		fnReturnType: "void",
		fnDefaults: [],
		nativeName: dispatchNativeName,
		nameLocation: d.nameLocation,
	}, syntheticToken(loc));
	// Build Function type so codegen emits prototype (nodeType=null → skipped)
	const dispatchType = createFunction([createPtr(voidType()), createPtr(voidType())], ["this", "_dmsg"], voidType());
	fnNode.nodeType = dispatchType;
	const dispatchSym = makeSymbol(dispatchNativeName, SymbolKind.Function, dispatchType, false);
	dispatchSym.nativeName = dispatchNativeName;
	dispatchSym.state = SymbolState.Checked;
	fnNode.resolvedSym = dispatchSym;
	return fnNode;
}

// ===== Collect methods from actor body (unwrapping decorators) =====

function collectActorMethods(d: ActorDeclData): Node[] {
	const methods: Node[] = [];
	for (const member of d.actorBody) {
		let m = member;
		if (m.kind === NodeKind.DecoratedDecl) {
			const dd = m.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) m = dd.decoratedNode;
		}
		if (m.kind === NodeKind.MethodDecl) methods.push(m);
	}
	return methods;
}

// ===== ActorDecl → struct + handlers + proxies + dispatch =====

function lowerActorDecl(node: Node, loc: SourceLocation, ctx: TransformContext, dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[]): Node[] {
	const d = node.data as ActorDeclData;
	const name = d.actorName;
	const result: Node[] = [];

	result.push(emitActorStruct(node, d, loc));

	const methods = collectActorMethods(d);
	emitActorMethods(d, name, ctx, loc, result);

	// Track lifecycle hooks for wiring
	let hasOnTerminate = false;
	let hasOnExit = false;
	let hasOnDown = false;
	let hasOnIdle = false;
	let hasConstructor = false;
	for (const m of methods) {
		const md = m.data as MethodDeclData;
		if (md.methodName === "onTerminate") hasOnTerminate = true;
		if (md.methodName === "onExit") hasOnExit = true;
		if (md.methodName === "onDown") hasOnDown = true;
		if (md.methodName === "onIdle") hasOnIdle = true;
	}
	for (const member of d.actorBody) {
		let m = member;
		if (m.kind === NodeKind.DecoratedDecl) {
			const dd = m.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) m = dd.decoratedNode;
		}
		if (m.kind === NodeKind.ConstructorDecl) hasConstructor = true;
	}
	wireInfos.push({
		name,
		hasOnTerminate,
		hasSysMsg: hasOnExit || hasOnDown || hasOnIdle,
		hasTrapExits: hasOnExit,
		hasCtor: hasConstructor,
	});

	// Emit system message handler if actor has onExit or onDown
	if (hasOnExit || hasOnDown || hasOnIdle) {
		const sysHandlerName = name + "_systemMsg_impl";
		const actorRefType = createRef(createStruct(name, [], [], true));
		const selfIdent = makeIdent("this", loc);
		selfIdent.nodeType = actorRefType;
		const stmts: Node[] = [];
		// Cast void* this to actor Ref type
		const castThis = createNode(NodeKind.HiddenStdConv, { convExpr: selfIdent, convType: actorRefType }, syntheticToken(loc));
		castThis.nodeType = actorRefType;
		const selfDecl = makeVarDecl("_self", castThis, DeclKind.Const, loc);
		selfDecl.nodeType = actorRefType;
		stmts.push(selfDecl);
		const selfRef = makeIdent("_self", loc);
		selfRef.nodeType = actorRefType;

		// if (msMsgKind(_smsg) === -1 && hasOnExit) → call onExit_impl(_self, pid, reason)
		if (hasOnExit) {
			const kindCheck = makeBinary(
				makeCall(makeIdent("msMsgKind", loc), [makeIdent("_smsg", loc)], loc),
				"===", makeNumber(-1, loc), loc);
			const exitCall = makeCall(makeIdent(name + "_onExit_impl", loc), [
				selfRef,
				makeCall(makeIdent("msMsgGetDouble", loc), [makeIdent("_smsg", loc), makeNumber(0, loc)], loc),
				makeCall(makeIdent("msMsgGetDouble", loc), [makeIdent("_smsg", loc), makeNumber(1, loc)], loc),
			], loc);
			stmts.push(createNode(NodeKind.IfStmt, {
				condition: kindCheck, consequent: makeBlock([makeExprStmt(exitCall, loc)], loc),
				alternate: makeBlock([], loc),
			}, syntheticToken(loc)));
		}
		// if (msMsgKind(_smsg) === -2 && hasOnDown) → call onDown_impl(_self, ref, pid, reason)
		if (hasOnDown) {
			const kindCheck2 = makeBinary(
				makeCall(makeIdent("msMsgKind", loc), [makeIdent("_smsg", loc)], loc),
				"===", makeNumber(-2, loc), loc);
			const downCall = makeCall(makeIdent(name + "_onDown_impl", loc), [
				selfRef,
				makeCall(makeIdent("msMsgGetDouble", loc), [makeIdent("_smsg", loc), makeNumber(0, loc)], loc),
				makeCall(makeIdent("msMsgGetDouble", loc), [makeIdent("_smsg", loc), makeNumber(1, loc)], loc),
				makeCall(makeIdent("msMsgGetDouble", loc), [makeIdent("_smsg", loc), makeNumber(2, loc)], loc),
			], loc);
			stmts.push(createNode(NodeKind.IfStmt, {
				condition: kindCheck2, consequent: makeBlock([makeExprStmt(downCall, loc)], loc),
				alternate: makeBlock([], loc),
			}, syntheticToken(loc)));
		}
		// if (msMsgKind(_smsg) === -3 && hasOnIdle) → call onIdle_impl(_self)
		if (hasOnIdle) {
			const kindCheck3 = makeBinary(
				makeCall(makeIdent("msMsgKind", loc), [makeIdent("_smsg", loc)], loc),
				"===", makeNumber(-3, loc), loc);
			const idleCall = makeCall(makeIdent(name + "_onIdle_impl", loc), [selfRef], loc);
			stmts.push(createNode(NodeKind.IfStmt, {
				condition: kindCheck3, consequent: makeBlock([makeExprStmt(idleCall, loc)], loc),
				alternate: makeBlock([], loc),
			}, syntheticToken(loc)));
		}

		const sysHandlerBody = makeBlock(stmts, loc);
		const sysHandlerNode = createNode(NodeKind.FunctionDecl, {
			fnName: sysHandlerName, params: ["this", "_smsg"],
			fnParamTypes: [name, "void"], fnBody: sysHandlerBody,
			fnFlags: "", fnReturnType: "void", fnDefaults: [],
			nativeName: sysHandlerName, nameLocation: d.nameLocation,
		}, syntheticToken(loc));
		const sysType = createFunction([createPtr(voidType()), createPtr(voidType())], ["this", "_smsg"], voidType());
		sysHandlerNode.nodeType = sysType;
		const sysSym = makeSymbol(sysHandlerName, SymbolKind.Function, sysType, false);
		sysSym.nativeName = sysHandlerName;
		sysSym.state = SymbolState.Checked;
		sysHandlerNode.resolvedSym = sysSym;
		result.push(sysHandlerNode);
	}

	if (methods.length > 0) {
		const dispatchNode = emitActorDispatch(d, name, methods, loc, result);
		result.push(dispatchNode);
		dispatchSyms.push(dispatchNode.resolvedSym);
		dispatchNames.push(name);
	}

	return result;
}

// ===== Program-level: expand ActorDecl + inject include + rewrite new =====

function expandActorDecls(program: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[], ctx: TransformContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const newStmts: Node[] = [];

	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.ActorDecl) {
			const ad = stmt.data as ActorDeclData;
			names.push(ad.actorName);
			const expanded = lowerActorDecl(stmt, stmt.location, ctx, dispatchSyms, dispatchNames, wireInfos);
			for (const n of expanded) newStmts.push(n);
			continue;
		}
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ActorDecl) {
				const ad = ed.exportedDecl.data as ActorDeclData;
				names.push(ad.actorName);
				const expanded = lowerActorDecl(ed.exportedDecl, ed.exportedDecl.location, ctx, dispatchSyms, dispatchNames, wireInfos);
				for (const n of expanded) {
					newStmts.push(createNode(NodeKind.ExportDecl, {
						exportedDecl: n,
					}, syntheticToken(stmt.location)));
				}
				continue;
			}
		}
		newStmts.push(stmt);
	}

	pd.programStmts = newStmts;

	// Inject @include for actor.h if actors were found
	if (names.length > 0 && ctx.checkerCtx !== null) {
		if (ctx.checkerCtx.includeDirectives !== "") {
			ctx.checkerCtx.includeDirectives = ctx.checkerCtx.includeDirectives + "\n";
		}
		ctx.checkerCtx.includeDirectives = ctx.checkerCtx.includeDirectives + "runtime/actor/actor.h";
	}

	return program;
}

// Per-actor wiring flags — tracks which lifecycle hooks need runtime wiring
interface ActorWireInfo {
	name: string;
	hasOnTerminate: boolean;
	hasSysMsg: boolean;
	hasTrapExits: boolean;
	hasCtor: boolean;
}

function findWireInfo(infos: ActorWireInfo[], actorName: string): ActorWireInfo {
	for (const info of infos) {
		if (info.name === actorName) return info;
	}
	return null as unknown as ActorWireInfo;
}

// ===== Generate actor pid wiring statements for a variable =====

function generateActorWiring(varName: string, varSym: Symbol | null, actorName: string, dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[], loc: SourceLocation, newExprNode: Node): Node[] {
	const result: Node[] = [];
	let dSym: Symbol | null = null;
	for (let di = 0; di < dispatchNames.length; di = di + 1) {
		if (dispatchNames[di] === actorName) { dSym = dispatchSyms[di]; }
	}
	const dispatchRef = dSym !== null
		? makeIdentResolved(dSym, loc)
		: makeIdent(actorName + "_dispatch", loc);
	// Use makeIdentResolved when we have the variable's symbol — required for
	// module-top-level vars whose mangled name is `<name>__Z85<modulePath>`.
	// makeIdent emits the bare identifier, which only works for function-local
	// variables (no mangle prefix). At module scope the bare name is undeclared
	// in the generated C and the build fails to link the actor wiring stmts.
	const varRef = function(): Node {
		return varSym !== null
			? makeIdentResolved(varSym, loc)
			: makeIdent(varName, loc);
	};
	const pidMember = function(): Node {
		const m = makeMember(varRef(), "pid", loc);
		m.nodeType = getSysType(TypeKind.Int64);
		return m;
	};
	const createCall = makeCall(makeIdent("msActorCreatePid", loc), [
		varRef(),
		dispatchRef,
	], loc);
	const assignActor = makeBinary(
		pidMember(),
		"=", createCall, loc
	);
	result.push(makeExprStmt(assignActor, loc));
	const pidRef = pidMember();
	const registerCall = makeCall(makeIdent("msActorRegister", loc), [
		makeCall(makeIdent("msActorFromPid", loc), [pidRef], loc),
	], loc);
	result.push(makeExprStmt(registerCall, loc));
	const increfCall = makeCall(makeIdent("msIncRef", loc), [
		varRef(),
	], loc);
	result.push(makeExprStmt(increfCall, loc));
	const wi = findWireInfo(wireInfos, actorName);
	if (wi !== null && wi.hasOnTerminate) {
		const pidRef2 = pidMember();
		const setTermCall = makeCall(makeIdent("msActorSetOnTerminate", loc), [
			makeCall(makeIdent("msActorFromPid", loc), [pidRef2], loc),
			makeIdent(actorName + "_onTerminate_impl", loc),
		], loc);
		result.push(makeExprStmt(setTermCall, loc));
	}
	if (wi !== null && wi.hasSysMsg) {
		const pidRef3 = pidMember();
		const setSysCall = makeCall(makeIdent("msActorSetSystemMsgHandler", loc), [
			makeCall(makeIdent("msActorFromPid", loc), [pidRef3], loc),
			makeIdent(actorName + "_systemMsg_impl", loc),
		], loc);
		result.push(makeExprStmt(setSysCall, loc));
	}
	if (wi !== null && wi.hasTrapExits) {
		const trapCall = makeCall(makeIdent("msActorTrapExits", loc), [
			pidMember(),
			makeNumber(1, loc),
		], loc);
		result.push(makeExprStmt(trapCall, loc));
	}
	if (wi !== null && wi.hasCtor && newExprNode !== null) {
		const ne = newExprNode.data as NewExprData;
		const ctorArgs: Node[] = [varRef()];
		if (ne.newArguments !== null) {
			for (const arg of ne.newArguments) ctorArgs.push(arg);
		}
		const ctorCall = makeCall(makeIdent(actorName + "_constructor", loc), ctorArgs, loc);
		result.push(makeExprStmt(ctorCall, loc));
	}
	return result;
}

// ===== Extract `new ActorType()` from arbitrary expression positions =====
// Handles cases like `actors.push(new Counter())` or `doSomething(new MyActor())`
// where the NewExpr is not directly in a VarDecl initializer.
// Returns pre-statements to inject before the original statement.

function extractActorNewExprs(stmt: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[], ctx: TransformContext): Node[] {
	// Skip VarDecl with direct NewExpr initializer — handled by existing code path
	if (stmt.kind === NodeKind.VariableDecl) {
		const vd = stmt.data as VariableDeclData;
		if (vd.initializer !== null && vd.initializer.kind === NodeKind.NewExpr) return [];
	}
	// Get the expression(s) from the statement. containsExprKind/replaceInExpr
	// use mapExprChildren which only traverses expression nodes, not statement wrappers.
	const targetExpr: Node | null = match (stmt.kind) {
		NodeKind.ExprStmt => (stmt.data as ExprStmtData).expr,
		NodeKind.VariableDecl => (stmt.data as VariableDeclData).initializer,
		NodeKind.ReturnStmt => (stmt.data as ReturnStmtData).argument,
		_ => null,
	};
	if (targetExpr === null) return [];
	if (!containsExprKind(targetExpr, NodeKind.NewExpr)) return [];

	const preStmts: Node[] = [];
	const replacer = (node: Node): Node => {
		if (node.kind !== NodeKind.NewExpr) return node;
		const ne = node.data as NewExprData;
		if (ne.newCallee.kind !== NodeKind.Identifier) return node;
		const id = ne.newCallee.data as IdentifierData;
		let actorName = "";
		for (const n of names) {
			if (n === id.name) actorName = n;
		}
		if (actorName === "") return node;
		const loc = node.location;
		const tmpSym = freshTempSym(ctx, "actor", node.nodeType);
		const tmpName = tmpSym.name;
		const tmpDecl = makeVarDecl(tmpName, node, DeclKind.Const, loc);
		tmpDecl.resolvedSym = tmpSym;
		preStmts.push(tmpDecl);
		const wiring = generateActorWiring(tmpName, tmpSym, actorName, dispatchSyms, dispatchNames, wireInfos, loc, node);
		for (const w of wiring) preStmts.push(w);
		return makeIdentResolved(tmpSym, loc);
	};
	const replaced = replaceInExpr(targetExpr, replacer);
	if (stmt.kind === NodeKind.ExprStmt) {
		(stmt.data as ExprStmtData).expr = replaced;
	} else if (stmt.kind === NodeKind.VariableDecl) {
		(stmt.data as VariableDeclData).initializer = replaced;
	} else if (stmt.kind === NodeKind.ReturnStmt) {
		(stmt.data as ReturnStmtData).argument = replaced;
	}
	return preStmts;
}

// ===== Wire actor creation after `new ActorType()` in any statement list =====

function wireActorInStmts(stmts: Node[], names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[], ctx: TransformContext): Node[] {
	const out: Node[] = [];
	for (const stmt of stmts) {
		// Recurse into nested blocks first
		wireActorInNode(stmt, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		// Extract `new ActorType()` from non-VarDecl-initializer positions into temp vars.
		// e.g. `actors.push(new Counter())` → `const _a0 = new Counter(); _a0.pid = ...; actors.push(_a0);`
		const preStmts = extractActorNewExprs(stmt, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		for (const ps of preStmts) out.push(ps);
		out.push(stmt);
		// After VarDecl with `new ActorType()`, inject pid wiring
		if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (vd.initializer !== null && vd.initializer.kind === NodeKind.NewExpr) {
				const ne = vd.initializer.data as NewExprData;
				if (ne.newCallee.kind === NodeKind.Identifier) {
					const id = ne.newCallee.data as IdentifierData;
					let actorName = "";
					for (const n of names) {
						if (n === id.name) actorName = n;
					}
					if (actorName !== "") {
						// Pass stmt.resolvedSym so the wiring stmts reference the
						// var via its mangled name (top-level vars get a module
						// suffix; bare `makeIdent(name)` would emit the unmangled
						// form and the C compiler would see an undeclared identifier).
						const wiring = generateActorWiring(vd.declName, stmt.resolvedSym, actorName, dispatchSyms, dispatchNames, wireInfos, stmt.location, vd.initializer);
						for (const w of wiring) out.push(w);
					}
				}
			}
		}
	}
	return out;
}

// ===== Recursively walk into nodes that contain statement lists =====

function wireActorInNode(node: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[], ctx: TransformContext): void {
	match (node.kind) {
		NodeKind.FunctionDecl => {
			const fd = node.data as FunctionDeclData;
			if (fd.fnBody !== null) wireActorInNode(fd.fnBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.ExportDecl => {
			// `export function foo() { const w = new Actor(); }` — drill into the
			// wrapped decl so the function body gets wired. Without this branch,
			// any `new ActorType()` inside an exported function is silently
			// skipped, leaving the actor pid uninitialized and SEND a no-op.
			const ed = node.data as ExportDeclData;
			if (ed.exportedDecl !== null) {
				wireActorInNode(ed.exportedDecl, names, dispatchSyms, dispatchNames, wireInfos, ctx);
			}
		},
		NodeKind.BlockStmt => {
			const bd = node.data as BlockStmtData;
			bd.statements = wireActorInStmts(bd.statements, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.IfStmt => {
			const id = node.data as IfStmtData;
			wireActorInNode(id.consequent, names, dispatchSyms, dispatchNames, wireInfos, ctx);
			if (id.alternate !== null) wireActorInNode(id.alternate, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.WhileStmt => {
			const wd = node.data as WhileStmtData;
			wireActorInNode(wd.whileBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.DoWhileStmt => {
			const dd = node.data as DoWhileStmtData;
			wireActorInNode(dd.doBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.ForOfStmt => {
			const fd = node.data as ForOfStmtData;
			wireActorInNode(fd.forOfBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.ForStmt => {
			const fd = node.data as ForStmtData;
			wireActorInNode(fd.forBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.TryCatchStmt => {
			const td = node.data as TryCatchStmtData;
			wireActorInNode(td.tryBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
			if (td.catchBody !== null) wireActorInNode(td.catchBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
			if (td.finallyBody !== null) wireActorInNode(td.finallyBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.SwitchStmt => {
			const sd = node.data as SwitchStmtData;
			for (const c of sd.switchCases) wireActorInNode(c, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.SwitchCase => {
			const sc = node.data as SwitchCaseData;
			sc.caseStmts = wireActorInStmts(sc.caseStmts, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		NodeKind.TestDecl => {
			const td = node.data as TestDeclData;
			wireActorInNode(td.testBody, names, dispatchSyms, dispatchNames, wireInfos, ctx);
		},
		_ => {},
	};
}

// ===== Top-level: wire actors at all scopes + inject poll at exit =====

function rewriteAndInjectPoll(program: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[], ctx: TransformContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;

	// Recursively wire actor creation at all scope levels
	pd.programStmts = wireActorInStmts(pd.programStmts, names, dispatchSyms, dispatchNames, wireInfos, ctx);

	// Drain all actor mailboxes at exit
	const exitLoc = program.location;
	pd.programStmts.push(makeExprStmt(makeCall(makeIdent("msActorPollAll", exitLoc), [], exitLoc), exitLoc));

	return program;
}

// ===== Phase 5: Pre-async extraction of suspending actor methods =====

// Check if an expression tree contains AwaitExpr anywhere (nested calls, binary, etc.)
function exprContainsAwait(expr: Node): boolean {
	return containsExprKind(expr, NodeKind.AwaitExpr);
}

// Check if a node tree contains any AwaitExpr (recursive, stops at function boundaries).
function bodyContainsAwait(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.AwaitExpr) return true;
	if (node.kind === NodeKind.FunctionDecl || node.kind === NodeKind.FunctionExpr
		|| node.kind === NodeKind.ArrowFunction) return false;
	return match (node.kind) {
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let f = false;
			for (const s of d.statements) { if (!f && bodyContainsAwait(s)) { f = true; } }
			return f;
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			return bodyContainsAwait(d.consequent) || bodyContainsAwait(d.alternate);
		},
		NodeKind.WhileStmt => bodyContainsAwait((node.data as WhileStmtData).whileBody),
		NodeKind.ForOfStmt => bodyContainsAwait((node.data as ForOfStmtData).forOfBody),
		NodeKind.ForStmt => bodyContainsAwait((node.data as ForStmtData).forBody),
		NodeKind.DoWhileStmt => bodyContainsAwait((node.data as DoWhileStmtData).doBody),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			return bodyContainsAwait(d.tryBody) || bodyContainsAwait(d.catchBody) || bodyContainsAwait(d.finallyBody);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			return d.expr !== null && exprContainsAwait(d.expr);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			return d.initializer !== null && exprContainsAwait(d.initializer);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			return d.argument !== null && exprContainsAwait(d.argument);
		},
		_ => false,
	};
}

// Pre-async pipeline: extract async actor methods as top-level FunctionDecl so
// asyncDesugar + asyncBridge can process them into stepper state machines.
// Marks extracted methods with methodFlags = "async_actor" sentinel for Phase B.
export function lowerActorPre(program: Node, ctx: TransformContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const extracted: Node[] = [];

	for (const stmt of pd.programStmts) {
		let actorNode = stmt;
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ActorDecl) {
				actorNode = ed.exportedDecl;
			}
		}
		if (actorNode.kind !== NodeKind.ActorDecl) continue;
		const d = actorNode.data as ActorDeclData;
		const name = d.actorName;

		for (const member of d.actorBody) {
			let m = member;
			if (m.kind === NodeKind.DecoratedDecl) {
				const dd = m.data as DecoratedDeclData;
				if (dd.decoratedNode !== null) m = dd.decoratedNode;
			}
			if (m.kind !== NodeKind.MethodDecl) continue;
			const md = m.data as MethodDeclData;
			// Skip lifecycle hooks — not message-dispatched
			const isLifecycle = match (md.methodName) {
				"onTerminate" | "onExit" | "onDown" | "onIdle" => true,
				_ => false,
			};
			if (isLifecycle) continue;
			// Detect: method is explicitly async OR its body contains await
			const isAsync = md.methodFlags === "async" || bodyContainsAwait(md.methodBody);
			if (!isAsync) continue;

			// Extract as top-level FunctionDecl with fnFlags: "async"
			const implNativeName = name + "_" + md.methodName + "_impl";
			// Plain-ref MOVE release now covers ASYNC void methods too: the
			// release wrapper puts the body in try/finally, and try×await
			// splits since the finallyPath port (corpus 420) — the finally
			// rides the async body's completion states. Non-void methods keep
			// BORROW (Amendment I: an awaited CALL holds the borrow on the
			// sender's frame), so they still pass isVoid=false.
			const implVoid = md.methodReturnType === "" || md.methodReturnType === "void";
			const implNode = createNode(NodeKind.FunctionDecl, {
				fnName: implNativeName,
				params: md.methodParams,
				fnParamTypes: md.methodParamTypes,
				fnBody: wrapImplBodyWithShareRelease(md.methodBody, md.methodParams, m.nodeType !== null ? m.nodeType.typeChildren : null, implVoid, ctx, actorNode.location),
				fnFlags: "async",
				fnReturnType: md.methodReturnType,
				fnDefaults: [],
				nativeName: implNativeName,
				nameLocation: md.nameLocation,
			}, syntheticToken(actorNode.location));
			// Wrap return type in Promise<T> so asyncBridge can extract the inner type.
			// The method's original type is (self, args) → T; we need (self, args) → Promise<T>.
			let implType = m.nodeType;
			if (implType !== null && implType.kind === TypeKind.Function && implType.typeReturn !== null) {
				const promiseRet = createPromise(implType.typeReturn);
				implType = createFunction(
					implType.typeChildren !== null ? implType.typeChildren : [],
					implType.typeNames !== null ? implType.typeNames : [],
					promiseRet,
				);
			}
			implNode.nodeType = implType;
			implNode.typeExprs = m.typeExprs;
			implNode.paramLocations = m.paramLocations;
			const implSym = makeSymbol(implNativeName, SymbolKind.Function,
				implType !== null ? implType : noneType(), false);
			implSym.nativeName = implNativeName;
			implSym.state = SymbolState.Checked;
			implNode.resolvedSym = implSym;
			extracted.push(implNode);

			// Mark as extracted so emitActorMethods (Phase B) skips _impl creation.
			// Clear the original body to prevent double-processing by intermediate passes
			// (e.g., spawnLower walking into both the ActorDecl and the extracted _impl).
			md.methodFlags = "async_actor";
			md.methodBody = makeBlock([], actorNode.location);
		}
	}

	// Append extracted _impl functions to program top-level
	if (extracted.length > 0) {
		for (const fn of extracted) {
			pd.programStmts.push(fn);
		}
	}
	return program;
}

// ===== Entry Point =====

export function lowerActor(program: Node, ctx: TransformContext): Node {
	const names: string[] = [];
	const dispatchSyms: Symbol[] = [];
	const dispatchNames: string[] = [];
	const wireInfos: ActorWireInfo[] = [];
	const expanded = expandActorDecls(program, names, dispatchSyms, dispatchNames, wireInfos, ctx);
	if (names.length === 0) return expanded;
	return rewriteAndInjectPoll(expanded, names, dispatchSyms, dispatchNames, wireInfos, ctx);
}
