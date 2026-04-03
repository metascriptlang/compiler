// Actor Lowering — transform ActorDecl into async actor infrastructure
//
// After this pass, zero ActorDecl nodes remain. DRC and codegen see:
// - ClassDecl (state struct with _actor field)
// - FunctionDecl _impl handlers (original method bodies, called by dispatch)
// - FunctionDecl proxies (enqueue message via msActorSend — what callers invoke)
// - FunctionDecl dispatch (switches on msg kind, calls _impl handlers)
// - @include("std/runtime/actor.h") injected for C compilation

import { Node, NodeKind, SourceLocation, DeclKind,
	ActorDeclData, MethodDeclData, ConstructorDeclData,
	DecoratedDeclData, ExportDeclData, ProgramData, NewExprData,
	IdentifierData, VariableDeclData, Symbol, SymbolKind, SymbolState } from "../../ast/node";
import { TransformContext, freshTempSym } from "../context";
import { makeSymbol } from "../../checker/symbol";
import { syntheticToken, makeIdent, makeIdentResolved, makeCall, makeExprStmt, makeReturn,
	makeVarDecl, makeMember, makeNumber, makeNull, makeBlock,
	makeBinary } from "../util";
import { createNode } from "../../ast/node";
import { voidType, unknownType, int32Type, createFunction, createRef, createStruct } from "../../checker/types";

// ===== Build proxy body for a void method (send semantics) =====

function buildSendProxy(kind: number, ctx: TransformContext, loc: SourceLocation): Node {
	const msgSym = freshTempSym(ctx, "amsg", voidType());
	const msgAlloc = makeCall(makeIdent("msMsgAlloc", loc), [
		makeNumber(kind, loc),
		makeNull(loc),
	], loc);
	msgAlloc.nodeType = voidType();
	const msgDecl = makeVarDecl(msgSym.name, msgAlloc, DeclKind.Const, loc);
	msgDecl.resolvedSym = msgSym;
	msgDecl.nodeType = voidType();
	const sendCall = makeCall(makeIdent("msActorSend", loc), [
		makeMember(makeIdent("this", loc), "_actor", loc),
		makeIdentResolved(msgSym, loc),
	], loc);
	return makeBlock([msgDecl, makeExprStmt(sendCall, loc)], loc);
}

// ===== Build proxy body for a T-returning method (call semantics) =====

function buildCallProxy(kind: number, ctx: TransformContext, loc: SourceLocation): Node {
	const futSym = freshTempSym(ctx, "afut", voidType());
	const msgSym = freshTempSym(ctx, "amsg", voidType());
	const futCreate = makeCall(makeIdent("msFutureCreate", loc), [], loc);
	futCreate.nodeType = voidType();
	const futDecl = makeVarDecl(futSym.name, futCreate, DeclKind.Const, loc);
	futDecl.resolvedSym = futSym;
	futDecl.nodeType = voidType();
	const msgAlloc = makeCall(makeIdent("msMsgAlloc", loc), [
		makeNumber(kind, loc),
		makeIdentResolved(futSym, loc),
	], loc);
	msgAlloc.nodeType = voidType();
	const msgDecl = makeVarDecl(msgSym.name, msgAlloc, DeclKind.Const, loc);
	msgDecl.resolvedSym = msgSym;
	msgDecl.nodeType = voidType();
	const sendCall = makeCall(makeIdent("msActorSend", loc), [
		makeMember(makeIdent("this", loc), "_actor", loc),
		makeIdentResolved(msgSym, loc),
	], loc);
	const retFut = makeReturn(makeIdentResolved(futSym, loc), loc);
	return makeBlock([futDecl, msgDecl, makeExprStmt(sendCall, loc), retFut], loc);
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
		const cond = makeBinary(
			makeIdent("_dmsg", loc),
			"===",
			makeNumber(msgKind, loc),
			loc
		);
		const selfRef = makeIdent("_self", loc);
		selfRef.nodeType = actorRefType;
		const handlerCall = makeCall(makeIdent(actorName + "_" + md.methodName + "_impl", loc), [selfRef], loc);
		const body = makeBlock([makeExprStmt(handlerCall, loc)], loc);
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

// ===== Emit state struct (ClassDecl with _actor field) =====

function emitActorStruct(node: Node, d: ActorDeclData, loc: SourceLocation): Node {
	const structMembers: Node[] = [];
	structMembers.push(createNode(NodeKind.PropertyDecl, {
		propName: "_actor",
		propType: "void",
		propIsStatic: false,
		propInitializer: null as unknown as Node,
	}, syntheticToken(loc)));
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
			result.push(implNode);

			// Proxy: enqueues message (what extensionMethodLower resolves to)
			const proxyBody = isVoid
				? buildSendProxy(msgKind, ctx, loc)
				: buildCallProxy(msgKind, ctx, loc);
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
		fnParamTypes: [name, "int32"],
		fnBody: dispatchBody,
		fnFlags: "",
		fnReturnType: "void",
		fnDefaults: [],
		nativeName: dispatchNativeName,
		nameLocation: d.nameLocation,
	}, syntheticToken(loc));
	// Build Function type so codegen emits prototype (nodeType=null → skipped)
	const dispatchType = createFunction([unknownType(), int32Type()], ["this", "_dmsg"], voidType());
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
		ctx.checkerCtx.includeDirectives = ctx.checkerCtx.includeDirectives + "std/runtime/actor.h";
	}

	return program;
}

// ===== Post-construction wiring for new Counter() =====

function rewriteNewAndVarDecls(program: Node, names: string[], dispatchSyms: Symbol[], dispatchNames: string[], ctx: TransformContext): Node {
	if (program.kind !== NodeKind.Program) return program;
	if (names.length === 0) return program;
	const pd = program.data as ProgramData;
	const newStmts: Node[] = [];

	for (const stmt of pd.programStmts) {
		newStmts.push(stmt);
		// After: const c = new Counter(); insert: c._actor = msActorCreate(c, Counter_dispatch); msActorRegister(c._actor);
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
						// Find dispatch symbol for this actor
						let dSym: Symbol = null as unknown as Symbol;
						for (let di = 0; di < dispatchNames.length; di = di + 1) {
							if (dispatchNames[di] === actorName) { dSym = dispatchSyms[di]; }
						}
						// c._actor = msActorCreate(c, Counter_dispatch)
						const dispatchRef = dSym !== null
							? makeIdentResolved(dSym, loc)
							: makeIdent(actorName + "_dispatch", loc);
						const createCall = makeCall(makeIdent("msActorCreate", loc), [
							makeIdent(vd.declName, loc),
							dispatchRef,
						], loc);
						const assignActor = makeBinary(
							makeMember(makeIdent(vd.declName, loc), "_actor", loc),
							"=",
							createCall,
							loc
						);
						newStmts.push(makeExprStmt(assignActor, loc));
						// msActorRegister(c._actor)
						const registerCall = makeCall(makeIdent("msActorRegister", loc), [
							makeMember(makeIdent(vd.declName, loc), "_actor", loc),
						], loc);
						newStmts.push(makeExprStmt(registerCall, loc));
					}
				}
			}
		}
	}

	// Append msActorPollAll() at program exit to drain all pending messages.
	// Single-threaded: messages are enqueued synchronously, poll drains them all.
	// Multi-scheduler replaces this with a proper event loop.
	const exitLoc = program.location;
	const pollCall = makeCall(makeIdent("msActorPollAll", exitLoc), [], exitLoc);
	newStmts.push(makeExprStmt(pollCall, exitLoc));

	pd.programStmts = newStmts;
	return program;
}

// ===== Entry Point =====

export function lowerActor(program: Node, ctx: TransformContext): Node {
	const names: string[] = [];
	const dispatchSyms: Symbol[] = [];
	const dispatchNames: string[] = [];
	const expanded = expandActorDecls(program, names, dispatchSyms, dispatchNames, ctx);
	if (names.length === 0) return expanded;
	return rewriteNewAndVarDecls(expanded, names, dispatchSyms, dispatchNames, ctx);
}
