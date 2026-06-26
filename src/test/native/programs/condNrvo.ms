// Regression: a statement-emitting expression (NRVO struct/object/new) in a `?:`
// branch must be evaluated ONLY when that branch is taken — `?:` promises
// conditional evaluation. Before the fix, codegen emitted BOTH branches'
// `f(&tmp);` statements unconditionally before the C `?:`, so the untaken branch
// ran too: over-execution, or a crash when the untaken branch was only valid under
// the condition. `?:` now lowers to temp+if/else (matchLower / Reference genIf
// parity). Locks four value positions: direct var-init, guard pattern, nested `?:`
// in a branch, and call-argument. Marker prints only if exactly the taken branches
// ran (runs==3) AND the guard's untaken crash-branch did NOT run (exit 0).

struct V { x: int32; y: int32; }

let runs: int32 = 0;

function mkA(): V { runs = runs + 1; return { x: 10, y: 0 }; }
function mkB(): V { runs = runs + 1; return { x: 20, y: 0 }; }
function sumV(v: V): int32 { return v.x + v.y; }
function first(arr: V[]): V { return arr[0]; }   // index 0 of empty → out-of-bounds crash

function main(): void {
	// Runtime-true condition (array access — not const-foldable away).
	const flags: int32[] = [1];
	const condT: boolean = flags[0] === 1;

	// 1. direct var-init: only mkA must run → runs == 1
	const a: V = condT ? mkA() : mkB();

	// 2. guard pattern: untaken branch first(empty) would crash — must NOT run
	const safe: V[] = [{ x: 5, y: 0 }];
	const empty: V[] = [];
	const g: V = condT ? first(safe) : first(empty);

	// 3. nested ?: in a branch — inner must hoist into the guarded scope → runs == 2
	const n: V = condT ? (a.x > 0 ? mkA() : mkB()) : mkB();

	// 4. call-argument position (ternary nested in an unconditional call) → runs == 3
	const s: int32 = sumV(condT ? mkA() : mkB());

	// 5. ternary nested in another ternary's CONDITION (unconditional position) → runs == 4
	const m: int32 = ((condT ? mkA() : mkB()).x > 5) ? 1 : 2;

	// a.x=10, g.x=5, n.x=10, s=10, m=1, runs=4 → 40
	const acc: int32 = (a.x + g.x + n.x + s + m + runs) as int32;
	console.log(`cond-nrvo acc=${acc}`);
}
