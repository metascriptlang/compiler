// @maxrss: 40
// @stdout: actor-shared-actor-field done
// @serial
// @skip-js: std/actor has no js binding - the actor runtime is C-only (PARALOCK tier 2/3); js audit 2026-09-01
// note: FIXED (UAF caught by audit of the actor-state-free fix): an actor whose state holds OTHER actor handles (plain Ref / array element / nullable union) double-freed the shared actor on teardown. Actors are DRC-exempt (classify.ms: SymbolKind.Actor -> noRcInfo), spawn never increfs the handle, so a generated destroy/copy hook touching the field underflowed the shared actor's rc; once the actor-state-free fix wired the with-ctor destroyFn, the orphaned hook ran and double-freed. Root cause: destructorLifting had no actor exemption while classify.ms did. Fixes mirror classify.ms: destructorLifting skips RC ops on actor-typed Ref fields (fillBody) and actor-element arrays (arrayOp), and codegen picks the free-only msNumberArrayDestroy for an actor-element ref-array box (no per-element decref). Pre-fix: ASAN heap-use-after-free / malloc abort under --gc=drc+orc.

// Guards the actor-field DRC exemption. An actor whose state holds OTHER actor
// handles — as a plain Ref, an array element, or a nullable union — must NOT decref
// those handles on teardown: actors are DRC-exempt (classify.ms), spawn never increfs
// them, so a generated destroy/copy hook that touches them underflows the shared
// actor's rc and double-frees its state. Two coordinated fixes keep the transform/
// codegen in agreement with the analyzer: destructorLifting skips RC ops on actor-typed
// Ref fields + actor-element arrays, and the ref-array box destroyFn for an actor
// element is the free-only msNumberArrayDestroy (no per-element decref). Pre-fix this
// double-freed (ASAN heap-use-after-free / malloc abort).

import { stop, ExitReason } from "std/actor";

actor Leaf {
	buf: string = "";
	size(): number { return this.buf.length; }
}

actor RefParent {
	child: Leaf = null as unknown as Leaf;
	constructor(c: Leaf) { this.child = c; }
	tag(): number { return 1; }
}

actor PoolParent {
	kids: Leaf[] = [];
	constructor(a: Leaf, b: Leaf) { this.kids = [a, b]; }
	count(): number { return this.kids.length; }
}

actor NullParent {
	child: Leaf | null = null;
	constructor(c: Leaf) { this.child = c; }
	has(): number { return 1; }
}

function main(): void {
	let acc = 0;
	for (let i = 0; i < 50000; i = i + 1) {
		const l1 = new Leaf();
		const l2 = new Leaf();
		const r1 = new RefParent(l1);
		const r2 = new RefParent(l1);
		const p = new PoolParent(l1, l2);
		const n = new NullParent(l2);
		stop(r1.pid, ExitReason.Normal);
		stop(r2.pid, ExitReason.Normal);
		stop(p.pid, ExitReason.Normal);
		stop(n.pid, ExitReason.Normal);
		stop(l1.pid, ExitReason.Normal);
		stop(l2.pid, ExitReason.Normal);
		acc = (acc + 1) % 1000;
	}
	console.log(`actor-shared-actor-field done acc=${acc}`);
}
main();
