import { Node, NodeKind, DeclKind, SourceLocation, Symbol, VariableDeclData, Type } from "../../ast/node";
import { SymSet, createSymSet, symSetAdd, symSetContains } from "../context";
import { isFuncBoundary } from "../walker";
import { forEachChild, anyChild } from "../../ast/visitor";
import {
	makeMember, makeBlock, makeVarDecl, makeObjectLiteral, makeNull, makeAssign, makeExprStmt,
	resolveSimpleTypeStr, extractBodyStmts,
} from "../util";
import { createRef } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { symIn, iterationBodyOf, collectIterationDecls } from "./lambdaLiftingDetect";
import { findCapturedIdent } from "./lambdaLiftingCaptures";
import {
	UP_FIELD, freshEnvVarSym, envVarRef, envVarDeref, PendingEnvRewrite, LoopEnv, LiftState, typeToEnvStr,
	makeEnvStruct, envHasField, chainIndexOf, isRoutineSym, routineInfoOf,
} from "./lambdaLiftingEnv";

function collectClosureReads(n: Node | null, inClosure: boolean, syms: SymSet, out: SymSet): void {
	if (n == null) return;
	if (n.kind == NodeKind.Identifier) {
		if (inClosure && symSetContains(syms, n.resolvedSym)) symSetAdd(out, n.resolvedSym!);
		return;
	}
	const inner = inClosure || isFuncBoundary(n);
	forEachChild(n, (c: Node): void => { collectClosureReads(c, inner, syms, out); });
}

function iterationCaptures(body: Node, state: LiftState): Node[] {
	const decls: Node[] = [];
	collectIterationDecls(body, decls);
	if (decls.length == 0) return decls;
	const declSyms = createSymSet();
	for (const d of decls) {
		if (d.resolvedSym != null && !isRoutineSym(state, d.resolvedSym)) symSetAdd(declSyms, d.resolvedSym);
	}
	const read = createSymSet();
	collectClosureReads(body, false, declSyms, read);
	const out: Node[] = [];
	for (const d of decls) {
		if (symSetContains(read, d.resolvedSym)) out.push(d);
	}
	return out;
}

function collectLoopCaptured(n: Node | null, out: SymSet, state: LiftState): void {
	if (n == null || isFuncBoundary(n)) return;
	const body = iterationBodyOf(n);
	if (body != null) {
		for (const d of iterationCaptures(body, state)) symSetAdd(out, d.resolvedSym!);
	}
	forEachChild(n, (c: Node): void => { collectLoopCaptured(c, out, state); });
}

export function frameLoopSyms(body: Node, state: LiftState): SymSet {
	const out = createSymSet();
	forEachChild(body, (c: Node): void => { collectLoopCaptured(c, out, state); });
	return out;
}

export function loopEnvOf(state: LiftState, sym: Symbol | null): LoopEnv | null {
	if (sym == null) return null;
	for (let i = state.loopEnvs.length - 1; i >= 0; i -= 1) {
		if (symSetContains(state.loopEnvs[i].syms, sym)) return state.loopEnvs[i];
	}
	return null;
}

export function envChainFrom(loops: LoopEnv[], top: number, frameEnvName: string, frameEnvType: Type, frameChainNames: string[], frameChainTypes: Type[]): { names: string[], types: Type[] } {
	const names: string[] = [];
	const types: Type[] = [];
	for (let i = top; i >= 0; i -= 1) {
		names.push(loops[i].envName);
		types.push(loops[i].envStructType);
	}
	if (frameEnvName != "" && frameEnvType != null) {
		names.push(frameEnvName);
		types.push(frameEnvType);
		for (const n of frameChainNames) names.push(n);
		for (const t of frameChainTypes) types.push(t);
	}
	return { names, types };
}

export function frameChain(state: LiftState): { names: string[], types: Type[] } {
	return envChainFrom([], -1, state.sharedEnvName, state.sharedEnvStructType, state.sharedEnvChainNames, state.sharedEnvChainTypes);
}

export function innermostLoopHolding(loops: LoopEnv[], syms: SymSet): number {
	for (let i = loops.length - 1; i >= 0; i -= 1) {
		for (const s of syms.items) {
			if (symSetContains(loops[i].syms, s)) return i;
		}
	}
	return -1;
}

export function splitLoopCaptures(fullSet: SymSet, idents: Node[], loops: LoopEnv[], splitLocals: Symbol[]): { syms: SymSet, idents: Node[] } {
	const syms = createSymSet();
	const held: Node[] = [];
	if (splitLocals.length == 0) return { syms, idents: held };
	for (const sym of fullSet.items) {
		let inLoopEnv = false;
		for (const l of loops) {
			if (symSetContains(l.syms, sym)) inLoopEnv = true;
		}
		if (inLoopEnv || !symIn(splitLocals, sym)) continue;
		const ident = findCapturedIdent(sym, idents);
		if (ident == null) continue;
		symSetAdd(syms, sym);
		held.push(ident);
	}
	return { syms, idents: held };
}

export function loopsHoldAll(loops: LoopEnv[], top: number, syms: SymSet): boolean {
	for (const s of syms.items) {
		let held = false;
		for (let i = top; i >= 0 && !held; i -= 1) held = symSetContains(loops[i].syms, s);
		if (!held) return false;
	}
	return true;
}

function collectIterationSyms(n: Node | null, state: LiftState, syms: SymSet, routines: Node[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.VariableDecl) {
		const sym = n.resolvedSym;
		if (isRoutineSym(state, sym)) {
			routines.push(n);
		} else if (sym != null && !hasFlag(sym, SymbolFlag.Global)) {
			symSetAdd(syms, sym);
		}
	}
	if (isFuncBoundary(n)) return;
	forEachChild(n, (c: Node): void => { collectIterationSyms(c, state, syms, routines); });
}

function collectDeclaredWithin(n: Node | null, out: SymSet): void {
	if (n == null) return;
	if (n.kind == NodeKind.VariableDecl && n.resolvedSym != null) symSetAdd(out, n.resolvedSym);
	if (n.kind == NodeKind.TryCatchStmt && n.resolvedSym != null) symSetAdd(out, n.resolvedSym);
	if (isFuncBoundary(n) && n.paramSyms != null) {
		for (const p of n.paramSyms) symSetAdd(out, p);
	}
	forEachChild(n, (c: Node): void => { collectDeclaredWithin(c, out); });
}

function collectIdents(n: Node | null, out: Node[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.Identifier) {
		out.push(n);
		return;
	}
	forEachChild(n, (c: Node): void => { collectIdents(c, out); });
}

function closureReads(fn: Node, routines: Node[], own: SymSet, idents: Node[]): void {
	const units: Node[] = [fn];
	for (let i = 0; i < units.length; i += 1) {
		collectDeclaredWithin(units[i], own);
		const start = idents.length;
		collectIdents(units[i], idents);
		for (let k = start; k < idents.length; k += 1) {
			const sym = idents[k].resolvedSym;
			if (sym == null) continue;
			for (const r of routines) {
				const init = (r.data as VariableDeclData).initializer;
				if (r.resolvedSym != sym || init == null) continue;
				let seen = false;
				for (const u of units) {
					if (u == init) seen = true;
				}
				if (!seen) units.push(init);
			}
		}
	}
}

function heldPastIteration(sym: Symbol, state: LiftState): boolean {
	for (const l of state.loopEnvs) {
		if (symSetContains(l.syms, sym)) return true;
	}
	if (state.sharedEnvActive && envHasField(state, state.sharedEnvStructType, sym)) return true;
	if (chainIndexOf(state, state.sharedEnvChainTypes, sym) >= 0) return true;
	const info = routineInfoOf(state, sym);
	return info != null && info.envStructType != null;
}

function closureReachesPast(n: Node | null, inner: SymSet, routines: Node[], state: LiftState): boolean {
	if (n == null) return false;
	if (!isFuncBoundary(n)) {
		return anyChild(n, (c: Node): boolean => closureReachesPast(c, inner, routines, state));
	}
	const own = createSymSet();
	const idents: Node[] = [];
	closureReads(n, routines, own, idents);
	let inside = false;
	let past = false;
	for (const id of idents) {
		const sym = id.resolvedSym;
		if (sym == null || symSetContains(own, sym)) continue;
		if (symSetContains(inner, sym)) {
			inside = true;
		} else if (heldPastIteration(sym, state)) {
			past = true;
		}
	}
	return inside && past;
}

function iterationReachesPast(body: Node, state: LiftState): boolean {
	const inner = createSymSet();
	const routines: Node[] = [];
	collectIterationSyms(body, state, inner, routines);
	return closureReachesPast(body, inner, routines, state);
}

export function openLoopEnv(body: Node, state: LiftState, loc: SourceLocation): Node {
	if (!state.sharedEnvActive && state.sharedEnvName != "") return body;
	const decls = iterationCaptures(body, state);
	if (decls.length == 0) return body;
	state.closureCounter += 1;
	const counter = state.closureCounter;
	const envName = `$Env_${state.currentFnName}_loop${counter}`;
	let parentSym: Symbol | null = null;
	let parentType: Type = null as unknown as Type;
	if (state.loopEnvs.length > 0) {
		const outer = state.loopEnvs[state.loopEnvs.length - 1];
		parentSym = outer.envVarSym;
		parentType = outer.envStructType;
	} else if (state.sharedEnvActive) {
		parentSym = state.sharedEnvVarSym;
		parentType = state.sharedEnvStructType;
	}
	if (parentSym != null && !iterationReachesPast(body, state)) parentSym = null;
	const fieldSyms: Symbol[] = [];
	const fieldTypes: string[] = [];
	const resolved: Type[] = [];
	if (parentSym != null) {
		fieldSyms.push(null as unknown as Symbol);
		fieldTypes.push("");
		resolved.push(createRef(parentType));
	}
	const syms = createSymSet();
	for (const d of decls) {
		const vd = d.data as VariableDeclData;
		if (symSetContains(syms, d.resolvedSym)) continue;
		symSetAdd(syms, d.resolvedSym!);
		const t = d.nodeType != null ? d.nodeType : resolveSimpleTypeStr(vd.declType);
		fieldSyms.push(d.resolvedSym!);
		fieldTypes.push(vd.declType != "" ? vd.declType : typeToEnvStr(t));
		resolved.push(t);
	}
	const envDecl = makeEnvStruct(state, envName, fieldSyms, fieldTypes, resolved, loc);
	state.envStructs.push(envDecl);
	const structType = envDecl.nodeType!;
	const envVarSym = freshEnvVarSym(state.ctx, `_envl${counter}_`, structType);
	const hoisted = makeVarDecl(envVarSym.name, makeNull(loc), DeclKind.Let, loc);
	hoisted.resolvedSym = envVarSym;
	hoisted.nodeType = createRef(structType);
	state.hoistedEnvDecls.push(hoisted);

	const stmts: Node[] = [];
	const fresh = makeObjectLiteral([], [], loc);
	fresh.nodeType = createRef(structType);
	stmts.push(makeExprStmt(makeAssign(envVarRef(envVarSym, structType, loc), fresh, loc), loc));
	if (parentSym != null) {
		const upLhs = makeMember(envVarDeref(envVarSym, structType, loc), UP_FIELD, loc);
		upLhs.nodeType = createRef(parentType);
		stmts.push(makeExprStmt(makeAssign(upLhs, envVarRef(parentSym, parentType, loc), loc), loc));
	}
	for (const s of extractBodyStmts(body)) stmts.push(s);

	state.loopEnvs.push({ envName, envVarSym, envStructType: structType, syms });
	const rewrites: PendingEnvRewrite[] = [{
		envVarSym, envStructType: structType, capturedSyms: syms,
		chainNames: [] as string[], chainTypes: [] as Type[], envVarDecl: null as unknown as Node, snapshotOnly: false,
	}];
	for (const rw of state.activeEnvRewrites) rewrites.push(rw);
	state.activeEnvRewrites = rewrites;
	return makeBlock(stmts, loc);
}
