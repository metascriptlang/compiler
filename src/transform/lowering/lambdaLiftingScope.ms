// Scope tracking primitives for lambda lifting (extracted for module modularity).
//
// Both the detection pass (`lambdaLiftingDetect.ms`) and the lift pass
// (`lambdaLifting.ms`) need scope-stack tracking with function-boundary awareness.
// Keeping these primitives in their own module avoids duplication and circular
// imports.

import { Symbol } from "../../ast/node";

// ===== Scope Stack =====
// Tracks variable declarations with function boundary awareness.

export interface ScopeStack {
	syms: Symbol[];
	spellings: string[];
	funcMarkers: number[];
	loopMarkers: number[];
}

export function createScopeStack(): ScopeStack {
	const ss: ScopeStack = { syms: [], spellings: [], funcMarkers: [], loopMarkers: [] };
	return ss;
}

export function pushFuncBoundary(ss: ScopeStack): void {
	ss.funcMarkers.push(ss.syms.length);
}

export function popFuncBoundary(ss: ScopeStack): void {
	const marker = ss.funcMarkers[ss.funcMarkers.length - 1];
	while (ss.syms.length > marker) {
		ss.syms.pop();
		ss.spellings.pop();
	}
	ss.funcMarkers.pop();
}

export function defineVar(ss: ScopeStack, sym: Symbol | null, name: string): void {
	ss.syms.push(sym as Symbol);
	ss.spellings.push(name);
}

export function defineParams(ss: ScopeStack, paramSyms: Symbol[] | null, params: string[]): void {
	for (let i = 0; i < params.length; i += 1) {
		defineVar(ss, paramSyms != null && i < paramSyms.length ? paramSyms[i] : null, params[i]);
	}
}

export function pushLoopBoundary(ss: ScopeStack): void {
	ss.loopMarkers.push(ss.syms.length);
}

export function popLoopBoundary(ss: ScopeStack): void {
	ss.loopMarkers.pop();
}

// Deep copy of the scope stack — every array cloned so the source remains
// independent of subsequent mutations. Used by the detection pass to fork a
// fresh frame for each function body without aliasing the parent walk's stack.
export function cloneScopeStack(ss: ScopeStack): ScopeStack {
	const syms: Symbol[] = [];
	for (const s of ss.syms) syms.push(s);
	const spellings: string[] = [];
	for (const n of ss.spellings) spellings.push(n);
	const markers: number[] = [];
	for (const m of ss.funcMarkers) markers.push(m);
	const loops: number[] = [];
	for (const m of ss.loopMarkers) loops.push(m);
	return { syms, spellings, funcMarkers: markers, loopMarkers: loops };
}

function boundIn(ss: ScopeStack, sym: Symbol, from: number, to: number): boolean {
	for (let i = from; i < to; i += 1) {
		if (ss.syms[i] == sym) return true;
	}
	return false;
}

export function isLocalVar(ss: ScopeStack, sym: Symbol): boolean {
	if (ss.funcMarkers.length == 0) return false;
	return boundIn(ss, sym, ss.funcMarkers[ss.funcMarkers.length - 1], ss.syms.length);
}

export function isOuterVar(ss: ScopeStack, sym: Symbol): boolean {
	if (ss.funcMarkers.length == 0) return false;
	return boundIn(ss, sym, 0, ss.funcMarkers[ss.funcMarkers.length - 1]);
}

// Reference parity (interestingVar): module-level symbols are always accessible
// as C globals. They don't need capture — global symbols are excluded from
// capture analysis. A variable is module-level if defined before the first
// function boundary marker.
export function isModuleLevelVar(ss: ScopeStack, sym: Symbol): boolean {
	if (ss.funcMarkers.length == 0) return true;
	return boundIn(ss, sym, 0, ss.funcMarkers[0]);
}

// Classify capture as direct parent local vs grandparent+. Direct parent =
// defined in the scope immediately before the current closure boundary.
// Grandparent = defined in an ancestor scope further up. Called AFTER
// tryLiftClosure pops the closure boundary — scope stack shows parent as
// last boundary. Used by lift to skip grandparent captures from per-closure
// envs (they're reached via the `$up` chain walk in `rewriteNode`).
export function isDirectParentVar(ss: ScopeStack, sym: Symbol): boolean {
	if (ss.funcMarkers.length < 2) return true;
	return boundIn(ss, sym, ss.funcMarkers[ss.funcMarkers.length - 2], ss.funcMarkers[ss.funcMarkers.length - 1]);
}

// A symbol-less reference spelled like an enclosing frame's binding cannot be
// matched to it: NIM-REF TR-11 forbids resolving a capture by name.
export function isOuterFrameName(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length < 2) return false;
	for (let i = ss.funcMarkers[0]; i < ss.funcMarkers[ss.funcMarkers.length - 1]; i += 1) {
		if (ss.spellings[i] == name) return true;
	}
	return false;
}
