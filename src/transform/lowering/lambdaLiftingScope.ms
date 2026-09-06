// Scope tracking primitives for lambda lifting (extracted for module modularity).
//
// Both the detection pass (`lambdaLiftingDetect.ms`) and the lift pass
// (`lambdaLifting.ms`) need scope-stack tracking with function-boundary awareness.
// Keeping these primitives in their own module avoids duplication and circular
// imports.

// ===== Scope Stack =====
// Tracks variable declarations with function boundary awareness.

export interface ScopeStack {
	names: string[];
	funcMarkers: number[];
	loopMarkers: number[];
}

export function createScopeStack(): ScopeStack {
	const ss: ScopeStack = { names: [], funcMarkers: [], loopMarkers: [] };
	return ss;
}

export function pushFuncBoundary(ss: ScopeStack): void {
	ss.funcMarkers.push(ss.names.length);
}

export function popFuncBoundary(ss: ScopeStack): void {
	const marker = ss.funcMarkers[ss.funcMarkers.length - 1];
	while (ss.names.length > marker) {
		ss.names.pop();
	}
	ss.funcMarkers.pop();
}

export function defineVar(ss: ScopeStack, name: string): void {
	ss.names.push(name);
}

export function pushLoopBoundary(ss: ScopeStack): void {
	ss.loopMarkers.push(ss.names.length);
}

export function popLoopBoundary(ss: ScopeStack): void {
	ss.loopMarkers.pop();
}

// A name bound at or past the innermost loop mark is re-bound on every
// iteration, so its storage is the per-iteration env rather than the function's
// shared env (NIM-REF row 115 addendum: the pair env's fields are complete and
// chain walks terminate there). Names bound before the mark keep one home for
// the whole call and stay in the shared env.
export function isLoopLocalVar(ss: ScopeStack, name: string): boolean {
	if (ss.loopMarkers.length == 0) return false;
	let i = ss.loopMarkers[ss.loopMarkers.length - 1];
	while (i < ss.names.length) {
		if (ss.names[i] == name) return true;
		i += 1;
	}
	return false;
}

// Deep copy of the scope stack — both arrays cloned so the source remains
// independent of subsequent mutations. Used by the detection pass to fork a
// fresh frame for each function body without aliasing the parent walk's stack.
export function cloneScopeStack(ss: ScopeStack): ScopeStack {
	const names: string[] = [];
	for (const n of ss.names) names.push(n);
	const markers: number[] = [];
	for (const m of ss.funcMarkers) markers.push(m);
	const loops: number[] = [];
	for (const m of ss.loopMarkers) loops.push(m);
	return { names, funcMarkers: markers, loopMarkers: loops };
}

export function isLocalVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length == 0) return false;
	const funcStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	for (let i = funcStart; i < ss.names.length; i += 1) {
		if (ss.names[i] == name) return true;
	}
	return false;
}

export function isOuterVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length == 0) return false;
	const funcStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	for (let i = 0; i < funcStart; i += 1) {
		if (ss.names[i] == name) return true;
	}
	return false;
}

// Reference parity (interestingVar): module-level symbols are always accessible
// as C globals. They don't need capture — global symbols are excluded from
// capture analysis. A variable is module-level if defined before the first
// function boundary marker.
export function isModuleLevelVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length == 0) return true;
	const firstBoundary = ss.funcMarkers[0];
	let i = 0;
	while (i < firstBoundary) {
		if (ss.names[i] == name) return true;
		i += 1;
	}
	return false;
}

// Classify capture as direct parent local vs grandparent+. Direct parent =
// defined in the scope immediately before the current closure boundary.
// Grandparent = defined in an ancestor scope further up. Called AFTER
// tryLiftClosure pops the closure boundary — scope stack shows parent as
// last boundary. Used by lift to skip grandparent captures from per-closure
// envs (they're reached via the `$up` chain walk in `rewriteNode`).
export function isDirectParentVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length < 2) return true;
	const parentStart = ss.funcMarkers[ss.funcMarkers.length - 2];
	const myStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	let i = parentStart;
	while (i < myStart) {
		if (ss.names[i] == name) return true;
		i += 1;
	}
	return false;
}

// ===== Built-in Names =====
// Names that are always accessible globally — never captured.
export function isBuiltinName(name: string): boolean {
	return match (name) {
		"console" | "Result" | "true" | "false" | "null" | "undefined" |
		"NaN" | "Infinity" | "Math" | "JSON" | "parseInt" | "parseFloat" |
		"String" | "Number" | "Boolean" | "Array" | "Object" | "Error" |
		"Promise" | "Map" | "Set" | "HashMap" | "HashSet" | "require" | "module" | "exports" |
		"globalThis" | "check" | "test" | "testGroup" => true,
		_ => false,
	};
}
