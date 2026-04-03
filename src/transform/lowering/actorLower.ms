// Actor Lowering — transform ActorDecl into async actor infrastructure
//
// After this pass, zero ActorDecl nodes remain. DRC and codegen see:
// - ClassDecl (state struct with pid field)
// - FunctionDecl _impl handlers (original method bodies, called by dispatch)
// - FunctionDecl proxies (enqueue message via msActorSend — what callers invoke)
// - FunctionDecl dispatch (switches on msg kind, calls _impl handlers)
// - @include("runtime/actor/actor.h") injected for C compilation

import { Node, NodeKind, SourceLocation, DeclKind, Type, TypeKind,
	ActorDeclData, MethodDeclData, ConstructorDeclData,
	DecoratedDeclData, ExportDeclData, ProgramData, NewExprData,
	IdentifierData, VariableDeclData, FunctionDeclData, IfStmtData,
	WhileStmtData, ForOfStmtData, ForStmtData, BlockStmtData,
	DoWhileStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData,
	Symbol, SymbolKind, SymbolState, createNode } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { makeSymbol } from "../../checker/symbol";
import {
	syntheticToken, makeIdent, makeIdentResolved, makeCall, makeExprStmt, makeReturn,
	makeVarDecl, makeMember, makeNumber, makeNull, makeBlock, makeBinary,
} from "../util";
import { voidType, unknownType, createFunction, createRef, createStruct, getSysType } from "../../checker/types";

// msMessage.data[56] holds 7 pointer-sized slots (56 / 8 on 64-bit).
const MS_MSG_MAX_ARGS = 7;

// Classify param type for message packing:
//   "double" → msMsgSetDouble/GetDouble (1 slot)
//   "string" → msMsgSetString/GetString (2 slots — msString is 16 bytes)
//   "ptr"    → msMsgSetPtr/GetPtr (1 slot — pointers, Ref<T>)
function paramMsgKind(paramTypes: Type[], idx: number): string {
	if (paramTypes === null || idx >= paramTypes.length) return "ptr";
	const t = paramTypes[idx];
	if (t === null) return "ptr";
	if (t.kind === TypeKind.String) return "string";
	if (t.kind === TypeKind.Number || t.kind === TypeKind.Float64 || t.kind === TypeKind.Float32
		|| t.kind === TypeKind.Int32 || t.kind === TypeKind.Int64
		|| t.kind === TypeKind.Int16 || t.kind === TypeKind.Int8
		|| t.kind === TypeKind.Uint32 || t.kind === TypeKind.Uint64
		|| t.kind === TypeKind.Uint16 || t.kind === TypeKind.Uint8
		|| t.kind === TypeKind.Boolean || t.kind === TypeKind.Enum) return "double";
	return "ptr";
}

// Slot width: strings use 2 slots (16 bytes), everything else 1 slot (8 bytes).
function paramSlotWidth(paramTypes: Type[], idx: number): number {
	return paramMsgKind(paramTypes, idx) === "string" ? 2 : 1;
}

// ===== Build proxy body for a void method (send semantics) =====

function totalSlotCount(params: string[], paramTypes: Type[]): number {
	let total = 0;
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		total = total + paramSlotWidth(paramTypes, ai);
	}
	return total;
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
	// Pack args into msg->data slots (skip params[0] = "this")
	// Strings use 2 slots (16B), everything else 1 slot (8B). Track slot offset.
	let slot = 0;
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		const mk = paramMsgKind(paramTypes, ai);
		const setter = mk === "double" ? "msMsgSetDouble" : mk === "string" ? "msMsgSetString" : "msMsgSetPtr";
		stmts.push(makeExprStmt(makeCall(makeIdent(setter, loc), [
			makeIdentResolved(msgSym, loc),
			makeNumber(slot, loc),
			makeIdent(params[ai], loc),
		], loc), loc));
		slot = slot + paramSlotWidth(paramTypes, ai);
	}
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
	// Pack args (same slot tracking as sendProxy)
	let slot = 0;
	for (let ai = 1; ai < params.length; ai = ai + 1) {
		const mk = paramMsgKind(paramTypes, ai);
		const setter = mk === "double" ? "msMsgSetDouble" : mk === "string" ? "msMsgSetString" : "msMsgSetPtr";
		stmts.push(makeExprStmt(makeCall(makeIdent(setter, loc), [
			makeIdentResolved(msgSym, loc),
			makeNumber(slot, loc),
			makeIdent(params[ai], loc),
		], loc), loc));
		slot = slot + paramSlotWidth(paramTypes, ai);
	}
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
			const getter = mk === "double" ? "msMsgGetDouble" : mk === "string" ? "msMsgGetString" : "msMsgGetPtr";
			const getCall = makeCall(makeIdent(getter, loc), [
				makeIdent("_dmsg", loc),
				makeNumber(dSlot, loc),
			], loc);
			handlerArgs.push(getCall);
			dSlot = dSlot + paramSlotWidth(mParamTypes, ai);
		}
		const handlerCall = makeCall(makeIdent(actorName + "_" + md.methodName + "_impl", loc), handlerArgs, loc);
		let body: Node;
		if (isVoid) {
			body = makeBlock([makeExprStmt(handlerCall, loc)], loc);
		} else {
			// Call-semantics: result = handler(); msMsgCompleteDouble(msMsgReplyFuture(_dmsg), result)
			const resultDecl = makeVarDecl("_result", handlerCall, DeclKind.Const, loc);
			const futAccessCall = makeCall(makeIdent("msMsgReplyFuture", loc), [makeIdent("_dmsg", loc)], loc);
			const completeCall = makeCall(makeIdent("msMsgCompleteDouble", loc), [futAccessCall, makeIdent("_result", loc)], loc);
			body = makeBlock([resultDecl, makeExprStmt(completeCall, loc)], loc);
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
			const isVoid = md.methodReturnType === "" || md.methodReturnType === "void";
			// Guard: data[56] inline buffer fits 7 args max (Pony uses per-behavior structs; we use fixed buffer)
			const argCount = md.methodParams.length - 1;
			if (argCount > MS_MSG_MAX_ARGS) {
				console.log(`warning: actor method '${name}.${md.methodName}' has ${argCount} args (max ${MS_MSG_MAX_ARGS} for inline message buffer)`);
			}

			// _impl handler: original body, nativeName for predictable C name
			const implNativeName = name + "_" + md.methodName + "_impl";
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
			// resolvedSym with Function type — DRC uses this for param type classification.
			// Without it, DRC falls back to lookupSymbol(paramName) which can find wrong-scope variables.
			const implSym = makeSymbol(implNativeName, SymbolKind.Function, m.nodeType !== null ? m.nodeType : unknownType(), false);
			implSym.nativeName = implNativeName;
			implSym.state = SymbolState.Checked;
			implNode.resolvedSym = implSym;
			result.push(implNode);

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
			const fnNode = createNode(NodeKind.FunctionDecl, {
				fnName: name + "_constructor",
				params: cd.ctorParams,
				fnParamTypes: cd.ctorParamTypes,
				fnBody: cd.ctorBody,
				fnFlags: "",
				fnReturnType: "",
				fnDefaults: cd.ctorDefaults,
				nativeName: "",
				nameLocation: loc,
			}, syntheticToken(loc));
			fnNode.resolvedSym = m.resolvedSym;
			fnNode.nodeType = m.nodeType;
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

function lowerActorDecl(node: Node, loc: SourceLocation, ctx: TransformContext, dispatchSyms: Symbol[], dispatchNames: string[]): Node[] {
	const d = node.data as ActorDeclData;
	const name = d.actorName;
	const result: Node[] = [];

	result.push(emitActorStruct(node, d, loc));

	const methods = collectActorMethods(d);
	emitActorMethods(d, name, ctx, loc, result);

	if (methods.length > 0) {
		const dispatchNode = emitActorDispatch(d, name, methods, loc);
		result.push(dispatchNode);
		dispatchSyms.push(dispatchNode.resolvedSym);
		dispatchNames.push(name);

	}

	return result;
}

// ===== Program-level: expand ActorDecl + inject include + rewrite new =====

function expandActorDecls(program: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], ctx: TransformContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const newStmts: Node[] = [];

	for (const stmt of pd.programStmts) {
		if (stmt.kind === NodeKind.ActorDecl) {
			const ad = stmt.data as ActorDeclData;
			names.push(ad.actorName);
			const expanded = lowerActorDecl(stmt, stmt.location, ctx, dispatchSyms, dispatchNames);
			for (const n of expanded) newStmts.push(n);
			continue;
		}
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ActorDecl) {
				const ad = ed.exportedDecl.data as ActorDeclData;
				names.push(ad.actorName);
				const expanded = lowerActorDecl(ed.exportedDecl, ed.exportedDecl.location, ctx, [], []);
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

// ===== Wire actor creation after `new ActorType()` in any statement list =====

function wireActorInStmts(stmts: Node[], names: string[], dispatchSyms: Symbol[], dispatchNames: string[]): Node[] {
	const out: Node[] = [];
	for (const stmt of stmts) {
		// Recurse into nested blocks first
		wireActorInNode(stmt, names, dispatchSyms, dispatchNames);
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
					}
				}
			}
		}
	}
	return out;
}

// ===== Recursively walk into nodes that contain statement lists =====

function wireActorInNode(node: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[]): void {
	if (node.kind === NodeKind.FunctionDecl) {
		const fd = node.data as FunctionDeclData;
		if (fd.fnBody !== null) wireActorInNode(fd.fnBody, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		bd.statements = wireActorInStmts(bd.statements, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.IfStmt) {
		const id = node.data as IfStmtData;
		wireActorInNode(id.consequent, names, dispatchSyms, dispatchNames);
		if (id.alternate !== null) wireActorInNode(id.alternate, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.WhileStmt) {
		const wd = node.data as WhileStmtData;
		wireActorInNode(wd.whileBody, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.DoWhileStmt) {
		const dd = node.data as DoWhileStmtData;
		wireActorInNode(dd.doBody, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.ForOfStmt) {
		const fd = node.data as ForOfStmtData;
		wireActorInNode(fd.forOfBody, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.ForStmt) {
		const fd = node.data as ForStmtData;
		wireActorInNode(fd.forBody, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.TryCatchStmt) {
		const td = node.data as TryCatchStmtData;
		wireActorInNode(td.tryBody, names, dispatchSyms, dispatchNames);
		if (td.catchBody !== null) wireActorInNode(td.catchBody, names, dispatchSyms, dispatchNames);
		if (td.finallyBody !== null) wireActorInNode(td.finallyBody, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.SwitchStmt) {
		const sd = node.data as SwitchStmtData;
		for (const c of sd.switchCases) wireActorInNode(c, names, dispatchSyms, dispatchNames);
	} else if (node.kind === NodeKind.SwitchCase) {
		const sc = node.data as SwitchCaseData;
		sc.caseStmts = wireActorInStmts(sc.caseStmts, names, dispatchSyms, dispatchNames);
	}
}

// ===== Top-level: wire actors at all scopes + inject poll at exit =====

function rewriteAndInjectPoll(program: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[]): Node {
	if (program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;

	// Recursively wire actor creation at all scope levels
	pd.programStmts = wireActorInStmts(pd.programStmts, names, dispatchSyms, dispatchNames);

	// Drain all actor mailboxes at exit
	const exitLoc = program.location;
	pd.programStmts.push(makeExprStmt(makeCall(makeIdent("msActorPollAll", exitLoc), [], exitLoc), exitLoc));

	return program;
}

// ===== Entry Point =====

export function lowerActor(program: Node, ctx: TransformContext): Node {
	const names: string[] = [];
	const dispatchSyms: Symbol[] = [];
	const dispatchNames: string[] = [];
	const expanded = expandActorDecls(program, names, dispatchSyms, dispatchNames, ctx);
	if (names.length === 0) return expanded;
	// Wire msActorCreate after every `new ActorType()` at any scope + inject poll at exit
	return rewriteAndInjectPoll(expanded, names, dispatchSyms, dispatchNames);
}
