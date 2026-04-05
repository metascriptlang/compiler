// Branch-aware append-only name set — shared primitives for dataflow trackers.
//
// Both initTracker (definite assignment) and spawnAffinity (SpawnHandle
// consumption) need the same machinery: an append-only string[] with
// save/restore/merge semantics keyed by BreakState exhaustiveness. This
// module owns that machinery so the two trackers stay in sync and neither
// duplicates the merge logic.
//
// Design choice: strings (not Symbol references) avoid DRC refcount issues
// with truncation under save/restore.

// Branch exit classification for merge exhaustiveness.
export enum BreakState {
	BsNone,           // normal flow — branch contributes to merge
	BsBreakOrReturn,  // break/return — exits branch, doesn't affect merge
	BsNoReturn,       // raise/noreturn — never reaches merge point
}

// Intersection count entry for branch merging.
class NameCount {
	name: string;
	count: number;
}

// ===== Core Set Operations =====

// Idempotent append. Linear scan — sets stay small so O(n) is fine.
export function addName(list: string[], name: string): void {
	for (const existing of list) {
		if (existing === name) return;
	}
	list.push(name);
}

// Membership test.
export function hasName(list: string[], name: string): boolean {
	for (const existing of list) {
		if (existing === name) return true;
	}
	return false;
}

// Collect names appended between oldState and current length.
export function collectSince(list: string[], oldState: number): string[] {
	const result: string[] = [];
	let i = oldState;
	while (i < list.length) {
		result.push(list[i]);
		i = i + 1;
	}
	return result;
}

// ===== Branch Merging =====

function addToIntersection(counts: NameCount[], name: string, breakState: BreakState): void {
	for (const entry of counts) {
		if (entry.name === name) {
			if (breakState === BreakState.BsNone) {
				entry.count = entry.count + 1;
			}
			return;
		}
	}
	if (breakState === BreakState.BsNone) {
		counts.push({ name, count: 1 });
	} else {
		counts.push({ name, count: 0 });
	}
}

// Merge branch contributions into `list`. A name is promoted iff it appears
// in every non-exiting branch AND the construct is exhaustive.
export function mergeBranches(
	list: string[],
	oldState: number,
	branchSets: string[][],
	branchBreaks: BreakState[],
	isExhaustive: boolean,
): void {
	if (!isExhaustive) {
		// No else / no default → can't prove any name present on all paths
		list.length = oldState;
		return;
	}

	let toCover = 0;
	const counts: NameCount[] = [];

	let b = 0;
	while (b < branchSets.length) {
		const set = branchSets[b];
		const breakState = branchBreaks[b];

		if (breakState === BreakState.BsNone) {
			toCover = toCover + 1;
		}

		for (const name of set) {
			addToIntersection(counts, name, breakState);
		}
		b = b + 1;
	}

	// Restore to pre-branch state, then re-add only names in ALL non-exiting branches.
	list.length = oldState;

	if (toCover > 0) {
		for (const entry of counts) {
			if (entry.count >= toCover) {
				addName(list, entry.name);
			}
		}
	}
}

// ===== Tests =====

test "addName idempotent" {
	const s: string[] = [];
	addName(s, "x");
	addName(s, "x");
	assert s.length === 1;
}

test "hasName basic" {
	const s: string[] = [];
	assert !hasName(s, "x");
	addName(s, "x");
	assert hasName(s, "x");
}

test "collectSince slice" {
	const s: string[] = ["a"];
	const snap = s.length;
	addName(s, "b");
	addName(s, "c");
	const fresh = collectSince(s, snap);
	assert fresh.length === 2;
}

test "mergeBranches exhaustive both" {
	const s: string[] = [];
	mergeBranches(s, 0, [["x"], ["x"]],
		[BreakState.BsNone, BreakState.BsNone], true);
	assert hasName(s, "x");
}

test "mergeBranches exhaustive partial" {
	const s: string[] = [];
	mergeBranches(s, 0, [["x"], []],
		[BreakState.BsNone, BreakState.BsNone], true);
	assert !hasName(s, "x");
}

test "mergeBranches non-exhaustive drops all" {
	const s: string[] = [];
	mergeBranches(s, 0, [["x"]], [BreakState.BsNone], false);
	assert !hasName(s, "x");
}

test "mergeBranches exiting branch ignored" {
	const s: string[] = [];
	mergeBranches(s, 0, [[], ["x"]],
		[BreakState.BsBreakOrReturn, BreakState.BsNone], true);
	assert hasName(s, "x");
}

test "mergeBranches noreturn branch ignored" {
	const s: string[] = [];
	mergeBranches(s, 0, [[], ["x"]],
		[BreakState.BsNoReturn, BreakState.BsNone], true);
	assert hasName(s, "x");
}
