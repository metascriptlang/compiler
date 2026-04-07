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
	ExprStmtData, ReturnStmtData,
	Symbol, SymbolKind, SymbolState, createNode } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { containsExprKind } from "../walker";
import { makeSymbol } from "../../checker/symbol";
import {
	syntheticToken, makeIdent, makeIdentResolved, makeCall, makeExprStmt, makeReturn,
	makeVarDecl, makeMember, makeNumber, makeNull, makeBlock, makeBinary,
} from "../util";
import { voidType, unknownType, createFunction, createPromise, createRef, createStruct, createPtr, createPrimitive, getSysType } from "../../checker/types";

// msMessage.data[56] holds 7 pointer-sized slots (56 / 8 on 64-bit).
const MS_MSG_MAX_ARGS = 7;
// void* type for HiddenStdConv casts in actor message packing/completion.
const VOID_PTR: Type = createPtr(createPrimitive(TypeKind.Void));

// Classify a Type for message slot packing:
//   "double" → msMsgSetDouble/GetDouble, msMsgCompleteDouble (1 slot, 8 bytes)
//   "string" → msMsgSetString/GetString, msMsgCompleteString (2 slots, 16 bytes)
//   "array"  → msMsgSetString/GetString + reinterpret cast (2 slots, 16 bytes — same layout as string)
//   "ptr"    → msMsgSetPtr/GetPtr, msMsgCompletePtr (1 slot — pointers, Ref<T>)
function typeMsgKind(t: Type): string {
	if (t === null) return "ptr";
	return match (t.kind) {
		TypeKind.String => "string",
		TypeKind.Array => "array",
		TypeKind.Number | TypeKind.Float64 | TypeKind.Float32
			| TypeKind.Int32 | TypeKind.Int64 | TypeKind.Int16 | TypeKind.Int8
			| TypeKind.Uint32 | TypeKind.Uint64 | TypeKind.Uint16 | TypeKind.Uint8
			| TypeKind.Boolean | TypeKind.Enum => "double",
		_ => "ptr",
	};
}

function paramMsgKind(paramTypes: Type[], idx: number): string {
	if (paramTypes === null || idx >= paramTypes.length) return "ptr";
	return typeMsgKind(paramTypes[idx]);
}

// Map message kind to C setter/getter function names
function msgSetterName(mk: string): string {
	return match (mk) {
		"double" => "msMsgSetDouble",
		"string" | "array" => "msMsgSetString",
		_ => "msMsgSetPtr",
	};
}

function msgGetterName(mk: string): string {
	return match (mk) {
		"double" => "msMsgGetDouble",
		"string" | "array" => "msMsgGetString",
		_ => "msMsgGetPtr",
	};
}

function msgCompleteName(mk: string): string {
	return match (mk) {
		"double" => "msMsgCompleteDouble",
		"string" => "msMsgCompleteString",
		"array" => "msMsgCompletePtr",
		_ => "msMsgCompletePtr",
	};
}

// Slot width: strings and arrays use 2 slots (16 bytes), everything else 1 slot (8 bytes).
function paramSlotWidth(paramTypes: Type[], idx: number): number {
	const mk = paramMsgKind(paramTypes, idx);
	return mk === "string" || mk === "array" ? 2 : 1;
}

// ===== Build proxy body for a void method (send semantics) =====

function totalSlotCount(params: string[], paramTypes: Type[]): number {
	let total = 0;
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		total = total + paramSlotWidth(paramTypes, ai);
	}
	return total;
}

// Pack method args into message data slots (shared by send and call proxies)
function packArgsIntoMsg(stmts: Node[], msgSym: Symbol, params: string[], paramTypes: Type[], loc: SourceLocation): void {
	let slot = 0;
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		const setter = msgSetterName(paramMsgKind(paramTypes, ai));
		stmts.push(makeExprStmt(makeCall(makeIdent(setter, loc), [
			makeIdentResolved(msgSym, loc),
			makeNumber(slot, loc),
			makeIdent(params[ai], loc),
		], loc), loc));
		slot = slot + paramSlotWidth(paramTypes, ai);
	}
}

function buildSendProxy(kind: number, params: string[], paramTypes: Type[], ctx: TransformContext, loc: SourceLocation): Node {
	const msgSym = freshTempSym(ctx, "amsg", voidType());
	const slotCount = totalSlotCount(params, paramTypes);
	const msgAlloc = makeCall(makeIdent("msMsgAllocSized", loc), [
		makeNumber(kind, loc),
		makeNull(loc),
		makeNumber(slotCount, loc),
	], loc);
	msgAlloc.nodeType = voidType();
	const msgDecl = makeVarDecl(msgSym.name, msgAlloc, DeclKind.Const, loc);
	msgDecl.resolvedSym = msgSym;
	msgDecl.nodeType = voidType();
	const stmts: Node[] = [msgDecl];
	packArgsIntoMsg(stmts, msgSym, params, paramTypes, loc);
	const actorPtr = makeCall(makeIdent("msActorFromPid", loc), [makeMember(makeIdent("this", loc), "pid", loc)], loc);
	const sendCall = makeCall(makeIdent("msActorSend", loc), [actorPtr, makeIdentResolved(msgSym, loc)], loc);
	stmts.push(makeExprStmt(sendCall, loc));
	return makeBlock(stmts, loc);
}

// ===== Build proxy body for a T-returning method (call semantics) =====

function buildCallProxy(kind: number, params: string[], paramTypes: Type[], ctx: TransformContext, loc: SourceLocation): Node {
	const futSym = freshTempSym(ctx, "afut", voidType());
	const msgSym = freshTempSym(ctx, "amsg", voidType());
	const futCreate = makeCall(makeIdent("msFutureCreate", loc), [], loc);
	futCreate.nodeType = voidType();
	const futDecl = makeVarDecl(futSym.name, futCreate, DeclKind.Const, loc);
	futDecl.resolvedSym = futSym;
	futDecl.nodeType = voidType();
	const slotCount = totalSlotCount(params, paramTypes);
	const msgAlloc = makeCall(makeIdent("msMsgAllocSized", loc), [
		makeNumber(kind, loc),
		makeIdentResolved(futSym, loc),
		makeNumber(slotCount, loc),
	], loc);
	msgAlloc.nodeType = voidType();
	const msgDecl = makeVarDecl(msgSym.name, msgAlloc, DeclKind.Const, loc);
	msgDecl.resolvedSym = msgSym;
	msgDecl.nodeType = voidType();
	const stmts: Node[] = [futDecl, msgDecl];
	packArgsIntoMsg(stmts, msgSym, params, paramTypes, loc);
	const actorPtr2 = makeCall(makeIdent("msActorFromPid", loc), [makeMember(makeIdent("this", loc), "pid", loc)], loc);
	const sendCall = makeCall(makeIdent("msActorSend", loc), [actorPtr2, makeIdentResolved(msgSym, loc)], loc);
	stmts.push(makeExprStmt(sendCall, loc));
	const retFut = makeReturn(makeIdentResolved(futSym, loc), loc);
	stmts.push(retFut);
	return makeBlock(stmts, loc);
}

// ===== Build dispatch function body =====

function buildDispatchBody(methods: Node[], actorName: string, loc: SourceLocation): Node {
	const stmts: Node[] = [];
	// Cast void* this to actor's Ref type via HiddenStdConv (no C cast emitted — just type annotation).
	// This tells codegen the argument is already a pointer, preventing &() struct promotion.
	const actorRefType = createRef(createStruct(actorName, [], [], true));
	const thisIdent = makeIdent("this", loc);
	thisIdent.nodeType = unknownType();
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
			const getter = msgGetterName(mk);
			const getCall = makeCall(makeIdent(getter, loc), [
				makeIdent("_dmsg", loc),
				makeNumber(dSlot, loc),
			], loc);
			if (mk === "array" && ai < mParamTypes.length && mParamTypes[ai] !== null) {
				// msMsgGetString returns msString compound literal. Reinterpret as the
				// actual array type (identical binary layout: {int64_t len, T* p}).
				// Cursor flag → codegen emits *((TargetType*)&(expr)) which is a safe
				// bitcast for compound literals (have address in C99).
				const conv = createNode(NodeKind.HiddenStdConv, {
					convExpr: getCall,
					convType: mParamTypes[ai],
				}, syntheticToken(loc));
				conv.nodeType = mParamTypes[ai];
				conv.flags = conv.flags | NodeFlag.Cursor;
				handlerArgs.push(conv);
			} else if (mk === "ptr") {
				// msMsgGetPtr returns void*. _impl takes pointer (ccgIntroducedPtr).
				// void* → T* is implicit in C. Set nodeType so codegen temps use void*.
				getCall.nodeType = VOID_PTR;
				handlerArgs.push(getCall);
			} else {
				handlerArgs.push(getCall);
			}
			dSlot = dSlot + paramSlotWidth(mParamTypes, ai);
		}
		const handlerCall = makeCall(makeIdent(actorName + "_" + md.methodName + "_impl", loc), handlerArgs, loc);
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
				// CALL: store reply future, chain _impl's future → reply future
				const futAccessCall = makeCall(makeIdent("msMsgReplyFuture", loc), [makeIdent("_dmsg", loc)], loc);
				const replyDecl = makeVarDecl("_replyFut", futAccessCall, DeclKind.Const, loc);
				replyDecl.nodeType = VOID_PTR;
				bodyStmts.push(replyDecl);
				bodyStmts.push(makeExprStmt(
					makeCall(makeIdent("msFutureChain", loc), [makeIdent("_implFut", loc), makeIdent("_replyFut", loc)], loc), loc));
				replyFutArg = makeIdent("_replyFut", loc);
			}
			// Derive msActor* from _self.pid, pass reply future for R1 stop
			const actorPtr = makeCall(makeIdent("msActorFromPid", loc), [
				makeMember(makeIdent("_self", loc), "pid", loc),
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
			if (retMk === "array" && retType !== null) {
				const boxCall = makeCall(makeIdent("msSinkBoxStruct", loc), [makeIdent("_result", loc)], loc);
				boxCall.nodeType = retType;
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
				const implSym = makeSymbol(implNativeName, SymbolKind.Function, m.nodeType !== null ? m.nodeType : unknownType(), false);
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
					fnBody: md.methodBody,
					fnFlags: md.methodFlags,
					fnReturnType: md.methodReturnType,
					fnDefaults: [],
					nativeName: implNativeName,
					nameLocation: md.nameLocation,
				}, syntheticToken(loc));
				implNode.nodeType = m.nodeType;
				implNode.typeExprs = m.typeExprs;
				implNode.paramLocations = m.paramLocations;
				const implSym = makeSymbol(implNativeName, SymbolKind.Function, m.nodeType !== null ? m.nodeType : unknownType(), false);
				implSym.nativeName = implNativeName;
				implSym.state = SymbolState.Checked;
				implNode.resolvedSym = implSym;
				result.push(implNode);
			}

			// Proxy: enqueues message (what extensionMethodLower resolves to)
			const methodParamTypes = m.nodeType !== null ? m.nodeType.typeChildren : [];
			const proxyBody = isVoid
				? buildSendProxy(msgKind, md.methodParams, methodParamTypes, ctx, loc)
				: buildCallProxy(msgKind, md.methodParams, methodParamTypes, ctx, loc);
			const proxyParamTypes = m.nodeType !== null ? m.nodeType.typeChildren : [];
			const proxyRetType = isVoid ? voidType() : unknownType();
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

function emitActorDispatch(d: ActorDeclData, name: string, methods: Node[], loc: SourceLocation): Node {
	const dispatchNativeName = name + "_dispatch";
	const dispatchBody = buildDispatchBody(methods, name, loc);
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
	const dispatchType = createFunction([unknownType(), unknownType()], ["this", "_dmsg"], voidType());
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
		const sysType = createFunction([unknownType(), unknownType()], ["this", "_smsg"], voidType());
		sysHandlerNode.nodeType = sysType;
		const sysSym = makeSymbol(sysHandlerName, SymbolKind.Function, sysType, false);
		sysSym.nativeName = sysHandlerName;
		sysSym.state = SymbolState.Checked;
		sysHandlerNode.resolvedSym = sysSym;
		result.push(sysHandlerNode);
	}

	if (methods.length > 0) {
		const dispatchNode = emitActorDispatch(d, name, methods, loc);
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

// ===== Wire actor creation after `new ActorType()` in any statement list =====

function wireActorInStmts(stmts: Node[], names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[]): Node[] {
	const out: Node[] = [];
	for (const stmt of stmts) {
		// Recurse into nested blocks first
		wireActorInNode(stmt, names, dispatchSyms, dispatchNames, wireInfos);
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
						const loc = stmt.location;
						let dSym: Symbol = null as unknown as Symbol;
						for (let di = 0; di < dispatchNames.length; di = di + 1) {
							if (dispatchNames[di] === actorName) { dSym = dispatchSyms[di]; }
						}
						const dispatchRef = dSym !== null
							? makeIdentResolved(dSym, loc)
							: makeIdent(actorName + "_dispatch", loc);
						// msActorCreatePid returns int64 (pointer cast) — matches pid field type
						const createCall = makeCall(makeIdent("msActorCreatePid", loc), [
							makeIdent(vd.declName, loc),
							dispatchRef,
						], loc);
						const assignActor = makeBinary(
							makeMember(makeIdent(vd.declName, loc), "pid", loc),
							"=", createCall, loc
						);
						out.push(makeExprStmt(assignActor, loc));
						// msActorFromPid converts int64 back to msActor* for runtime calls
						const pidRef = makeMember(makeIdent(vd.declName, loc), "pid", loc);
						const registerCall = makeCall(makeIdent("msActorRegister", loc), [
							makeCall(makeIdent("msActorFromPid", loc), [pidRef], loc),
						], loc);
						out.push(makeExprStmt(registerCall, loc));
						// Keep actor state alive past DRC scope — registry holds a ref
						const increfCall = makeCall(makeIdent("msIncRef", loc), [
							makeIdent(vd.declName, loc),
						], loc);
						out.push(makeExprStmt(increfCall, loc));
						const wi = findWireInfo(wireInfos, actorName);
						if (wi !== null && wi.hasOnTerminate) {
							const pidRef2 = makeMember(makeIdent(vd.declName, loc), "pid", loc);
							const setTermCall = makeCall(makeIdent("msActorSetOnTerminate", loc), [
								makeCall(makeIdent("msActorFromPid", loc), [pidRef2], loc),
								makeIdent(actorName + "_onTerminate_impl", loc),
							], loc);
							out.push(makeExprStmt(setTermCall, loc));
						}
						if (wi !== null && wi.hasSysMsg) {
							const pidRef3 = makeMember(makeIdent(vd.declName, loc), "pid", loc);
							const setSysCall = makeCall(makeIdent("msActorSetSystemMsgHandler", loc), [
								makeCall(makeIdent("msActorFromPid", loc), [pidRef3], loc),
								makeIdent(actorName + "_systemMsg_impl", loc),
							], loc);
							out.push(makeExprStmt(setSysCall, loc));
						}
						if (wi !== null && wi.hasTrapExits) {
							const trapCall = makeCall(makeIdent("msActorTrapExits", loc), [
								makeMember(makeIdent(vd.declName, loc), "pid", loc),
								makeNumber(1, loc),
							], loc);
							out.push(makeExprStmt(trapCall, loc));
						}
						if (wi !== null && wi.hasCtor) {
							// Forward constructor args from `new Actor(args...)` to deferred constructor
							const ctorArgs: Node[] = [makeIdent(vd.declName, loc)];
							if (ne.newArguments !== null) {
								for (const arg of ne.newArguments) ctorArgs.push(arg);
							}
							const ctorCall = makeCall(makeIdent(actorName + "_constructor", loc), ctorArgs, loc);
							out.push(makeExprStmt(ctorCall, loc));
						}
					}
				}
			}
		}
	}
	return out;
}

// ===== Recursively walk into nodes that contain statement lists =====

function wireActorInNode(node: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[]): void {
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		if (fd.fnBody !== null) wireActorInNode(fd.fnBody, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		bd.statements = wireActorInStmts(bd.statements, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.IfStmt) {
		const id = node.data as IfStmtData;
		wireActorInNode(id.consequent, names, dispatchSyms, dispatchNames, wireInfos);
		if (id.alternate !== null) wireActorInNode(id.alternate, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.WhileStmt) {
		const wd = node.data as WhileStmtData;
		wireActorInNode(wd.whileBody, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.DoWhileStmt) {
		const dd = node.data as DoWhileStmtData;
		wireActorInNode(dd.doBody, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.ForOfStmt) {
		const fd = node.data as ForOfStmtData;
		wireActorInNode(fd.forOfBody, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.ForStmt) {
		const fd = node.data as ForStmtData;
		wireActorInNode(fd.forBody, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.TryCatchStmt) {
		const td = node.data as TryCatchStmtData;
		wireActorInNode(td.tryBody, names, dispatchSyms, dispatchNames, wireInfos);
		if (td.catchBody !== null) wireActorInNode(td.catchBody, names, dispatchSyms, dispatchNames, wireInfos);
		if (td.finallyBody !== null) wireActorInNode(td.finallyBody, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.SwitchStmt) {
		const sd = node.data as SwitchStmtData;
		for (const c of sd.switchCases) wireActorInNode(c, names, dispatchSyms, dispatchNames, wireInfos);
	} else if (node.kind === NodeKind.SwitchCase) {
		const sc = node.data as SwitchCaseData;
		sc.caseStmts = wireActorInStmts(sc.caseStmts, names, dispatchSyms, dispatchNames, wireInfos);
	}
}

// ===== Top-level: wire actors at all scopes + inject poll at exit =====

function rewriteAndInjectPoll(program: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], wireInfos: ActorWireInfo[]): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;

	// Recursively wire actor creation at all scope levels
	pd.programStmts = wireActorInStmts(pd.programStmts, names, dispatchSyms, dispatchNames, wireInfos);

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
			const implNode = createNode(NodeKind.FunctionDecl, {
				fnName: implNativeName,
				params: md.methodParams,
				fnParamTypes: md.methodParamTypes,
				fnBody: md.methodBody,
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
				implType !== null ? implType : unknownType(), false);
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
	return rewriteAndInjectPoll(expanded, names, dispatchSyms, dispatchNames, wireInfos);
}
