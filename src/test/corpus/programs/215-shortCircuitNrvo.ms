// note: Locks conditional evaluation of `&&`/`||` RHS that compiles to
// statements on C. A struct-returning (NRVO) call in a short-circuit RHS is
// statement-emitting (`mk(&tmp);`); pre-fix codegen flattened it out of the C
// `&&` so the RHS ran even when the guard was false — over-execution in EVERY
// statement position (var-init, return, call-arg, assignment, if-cond), or an
// OOB crash for the guard idiom `len > 0 && first(arr).x > 5`. Scalar
// raise-checked calls in RHS were never affected (they stay C expressions and
// C's `&&` short-circuits them — probe-verified 2026-08-05), so the runs
// counter only moves when a struct call actually executes. JS emits native
// `&&`/`||` and is the spec lane; the pass that fixes this is C-only, so
// byte-parity across lanes is a sound guard here (no @stdout needed).
// Expected: ea=er=eg=eh=eo=0, ek=1, ei=1, z=false, exit 0 on every lane.

struct V { x: int32; y: int32; }

let runs: int32 = 0;

function mk(): V { runs = runs + 1; return { x: 10, y: 0 }; }
function first(arr: V[]): V { return arr[0]; }
function viaReturn(f: boolean): boolean { return f && (mk().x > 0); }
function sink(b: boolean): int32 { return b ? 1 : 0; }

function main(): void {
	const flags: int32[] = [];
	const f: boolean = flags.length > 0;
	const t: boolean = flags.length == 0;

	// 1. var-init: untaken && RHS must not run
	const a: boolean = f && (mk().x > 0);
	const ea: int32 = runs;

	// 2. return position
	const r: boolean = viaReturn(f);
	const er: int32 = runs;

	// 3. call-argument position
	const g: int32 = sink(f && (mk().x > 0));
	const eg: int32 = runs;

	// 4. assignment statement
	let h: boolean = true;
	h = f && (mk().x > 0);
	const eh: int32 = runs;

	// 5. || RHS with true guard must not run
	const o: boolean = t || (mk().x < 0);
	const eo: int32 = runs;

	// 6. taken && RHS runs exactly once
	const k: boolean = t && (mk().x > 0);
	const ek: int32 = runs;

	// 7. if-condition position
	if (f && (mk().x > 0)) { runs = runs + 100; }
	const ei: int32 = runs;

	// 8. guard idiom: RHS reads arr[0] of an empty array — OOB if over-executed
	const empty: V[] = [];
	const z: boolean = empty.length > 0 && (first(empty).x > 5);

	console.log(`seam1 a=${a} ea=${ea} r=${r} er=${er} g=${g} eg=${eg} h=${h} eh=${eh} o=${o} eo=${eo} k=${k} ek=${ek} ei=${ei} z=${z}`);
}
main();
