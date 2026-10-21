// Affine Tracking — PARALOCK Phase 1
//
// Tracks consumption of affine `Promise<T>` bindings (spawn-origin) through scopes, with branch
// awareness for R6 (must-consume on all paths).
//
// Uses a "symbol key" — name concatenated with declaration line:column — as
// the tracker identity, not bare names. This distinguishes shadowed bindings
// (same name, different declaration site) while keeping the save/restore
// pattern DRC-safe (string storage only, no Symbol references).
//
// Set + branch-merge primitives live in branchSet.ms and are shared with
// initTracker.ms so both trackers stay in lockstep.

import { Symbol } from "../ast/node";
import { BreakState, addName, hasName, collectSince, mergeBranches } from "./branchSet";

// Symbol identity key: name + ":" + declLine + ":" + declCol.
// Two symbols at the same source position are the same symbol; two with
// the same name at different positions (shadowing) get distinct keys.
export function symbolConsumeKey(sym: Symbol): string {
	if (sym == null) return "";
	const loc = sym.location;
	if (loc == null) return sym.name;
	return `${sym.name}:${loc.line}:${loc.column}`;
}

// Reference shape: effects.consumed flat list (mirror of InitTracker.initialized)
export interface AffineTracker {
	consumed: string[];   // append-only list of consumed affine Promise binding keys
	floor: int32;
	floors: int32[];
}

// ===== Constructors =====

export function createAffineTracker(): AffineTracker {
	return { consumed: [], floor: 0, floors: [] };
}

// ===== Core Operations (delegate to branchSet) =====

// Mark a affine Promise binding as consumed by key (idempotent).
export function markConsumedName(t: AffineTracker, name: string): void {
	addName(t.consumed, name);
}

// Check whether a keyed binding has been consumed.
export function isConsumedName(t: AffineTracker, name: string): boolean {
	return hasName(t.consumed, name);
}

// Save current consume state for branch rollback.
export function saveConsumeState(t: AffineTracker): int32 {
	t.floors.push(t.floor);
	t.floor = t.consumed.length;
	return t.consumed.length;
}

// Restore consume state.
export function restoreConsumeState(t: AffineTracker, state: int32): void {
	t.consumed.length = state;
}

export function leaveConsumeScope(t: AffineTracker, state: int32): void {
	t.consumed.length = state;
	t.floor = t.floors.pop()!;
}

export function reviveConsumedName(t: AffineTracker, key: string): void {
	for (let i = 0; i < t.floor; i += 1) {
		if (t.consumed[i] == key) return;
	}
	removeConsumedName(t, key);
}

// Collect names consumed between oldState and current state.
export function collectNewConsumes(t: AffineTracker, oldState: int32): string[] {
	return collectSince(t.consumed, oldState);
}

// ===== Branch Merging =====

// A name is promoted to "consumed" at the merge point iff it was consumed in
// every non-exiting branch AND the construct is exhaustive (has else / default).
export function mergeConsumeBranches(
	t: AffineTracker,
	oldState: int32,
	branchConsumes: string[][],
	branchBreaks: BreakState[],
	isExhaustive: boolean,
): void {
	mergeBranches(t.consumed, oldState, branchConsumes, branchBreaks, isExhaustive);
	t.floor = t.floors.pop()!;
}

// Remove a specific key from the consumed list. Stable order preserved.
// Used by the scope-exit check in checkPass to purge bindings going out of scope.
export function removeConsumedName(t: AffineTracker, key: string): void {
	let write = 0;
	let read = 0;
	while (read < t.consumed.length) {
		if (t.consumed[read] != key) {
			if (write != read) {
				t.consumed[write] = t.consumed[read];
			}
			write = write + 1;
		}
		read = read + 1;
	}
	t.consumed.length = write;
}

// ===== Tests =====

test "basic consume" {
	const t = createAffineTracker();
	assert !isConsumedName(t, "h");
	markConsumedName(t, "h");
	assert isConsumedName(t, "h");
	assert !isConsumedName(t, "other");
}

test "save and restore" {
	const t = createAffineTracker();
	markConsumedName(t, "a");
	const snap = saveConsumeState(t);
	markConsumedName(t, "b");
	assert isConsumedName(t, "b");
	restoreConsumeState(t, snap);
	assert isConsumedName(t, "a");
	assert !isConsumedName(t, "b");
}

test "no duplicate consume" {
	const t = createAffineTracker();
	markConsumedName(t, "h");
	markConsumedName(t, "h");
	assert t.consumed.length == 1;
}

test "merge exhaustive both consumed" {
	const t = createAffineTracker();
	const old = saveConsumeState(t);
	const b1: string[] = ["h"];
	const b2: string[] = ["h"];
	mergeConsumeBranches(t, old, [b1, b2],
		[BreakState.BsNone, BreakState.BsNone], true);
	assert isConsumedName(t, "h");
}

test "merge exhaustive one branch missing" {
	const t = createAffineTracker();
	const old = saveConsumeState(t);
	const b1: string[] = ["h"];
	const b2: string[] = [];
	mergeConsumeBranches(t, old, [b1, b2],
		[BreakState.BsNone, BreakState.BsNone], true);
	assert !isConsumedName(t, "h");
}

test "merge non-exhaustive" {
	const t = createAffineTracker();
	const old = saveConsumeState(t);
	const b1: string[] = ["h"];
	mergeConsumeBranches(t, old, [b1], [BreakState.BsNone], false);
	assert !isConsumedName(t, "h");
}

test "merge with exiting branch" {
	const t = createAffineTracker();
	const old = saveConsumeState(t);
	const b1: string[] = [];
	const b2: string[] = ["h"];
	// First branch breaks/returns (exits), second branch consumes → h consumed at merge
	mergeConsumeBranches(t, old, [b1, b2],
		[BreakState.BsBreakOrReturn, BreakState.BsNone], true);
	assert isConsumedName(t, "h");
}

test "merge with noreturn branch" {
	const t = createAffineTracker();
	const old = saveConsumeState(t);
	const b1: string[] = [];
	const b2: string[] = ["h"];
	mergeConsumeBranches(t, old, [b1, b2],
		[BreakState.BsNoReturn, BreakState.BsNone], true);
	assert isConsumedName(t, "h");
}

test "collectNewConsumes" {
	const t = createAffineTracker();
	markConsumedName(t, "a");
	const snap = saveConsumeState(t);
	markConsumedName(t, "b");
	markConsumedName(t, "c");
	const newCons = collectNewConsumes(t, snap);
	assert newCons.length == 2;
}

test "a revive inside the branch that consumed clears the consume" {
	const t = createAffineTracker();
	const old = saveConsumeState(t);
	markConsumedName(t, "h");
	reviveConsumedName(t, "h");
	assert !isConsumedName(t, "h");
	mergeConsumeBranches(t, old, [collectNewConsumes(t, old)], [BreakState.BsNone], false);
	assert t.floors.length == 0;
}

test "a revive in a branch keeps a consume made before the branch" {
	const t = createAffineTracker();
	markConsumedName(t, "h");
	const old = saveConsumeState(t);
	reviveConsumedName(t, "h");
	assert isConsumedName(t, "h");
	assert t.consumed.length == old;
}

test "a revive after a nested branch closes still clears the outer consume" {
	const t = createAffineTracker();
	const loop = saveConsumeState(t);
	markConsumedName(t, "h");
	const inner = saveConsumeState(t);
	mergeConsumeBranches(t, inner, [collectNewConsumes(t, inner)], [BreakState.BsNone], false);
	reviveConsumedName(t, "h");
	assert !isConsumedName(t, "h");
	leaveConsumeScope(t, loop);
	assert t.floor == 0;
}
