// nim-guard: evicting an atomic-rc cell from an array releases it atomically
//
// INVARIANT: the helper that evicts an element is picked by the ELEMENT's type,
//   the same way the reference lifts a seq's ops through fillBody(elemType) →
//   atomicRefOp for a ref element. Our Ref elements collapse into the runtime
//   msRefArray family, whose eviction helpers (shrink, splice, splice-with-item)
//   hardcode the element release, so an atomic-rc cell — born at
//   MS_RC_INCREMENT — is never freed by a plain msDecref.
//
// WHAT IT PROTECTS: four surfaces reach the same helpers by different routes —
//   `splice(i, k)` and `setLength(n)` are std externs, `arr.length = n` is
//   sugar lowered in builtinLower, and `splice(i, k, item)` also takes a share
//   on the way in. A regression in one of them is invisible in the others, and
//   invisible without the ledger: every program below prints the right values.
//   A plain counted array stands in the SAME program so the atomic family can
//   never quietly take over the plain one.
//
// RED MEANS the eviction helper stopped being chosen by element type — run
//   /trace-nim on nativeLower's evictHelperName and on builtinLower's
//   lowerLengthAssign before touching this file.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).
// GUARD-BALANCE TOTAL

import { lockedRead } from "std/core/promise";

struct Pt { x: int32; }

interface Plain { tag: int32; }

function spliceOut(): int32 {
	const arr: Locked<int32>[] = [new Locked(1), new Locked(2), new Locked(3)];
	arr.splice(0, 2);
	return lockedRead(arr[0], (v: int32): int32 => v);
}

function spliceInPlace(): int32 {
	const arr: Locked<int32>[] = [new Locked(1), new Locked(2), new Locked(3)];
	arr.splice(0, 2, new Locked(9));
	let sum = 0;
	for (const c of arr) { sum = sum + lockedRead(c, (v: int32): int32 => v); }
	return sum;
}

function shrinkBySetLength(): int32 {
	const arr: Locked<int32>[] = [new Locked(4), new Locked(5), new Locked(6)];
	arr.setLength(1);
	return lockedRead(arr[0], (v: int32): int32 => v);
}

function shrinkByLengthAssign(): int32 {
	const arr: Arc<Pt>[] = [new Arc<Pt>({ x: 7 }), new Arc<Pt>({ x: 8 })];
	arr.length = 1;
	return arr[0].x;
}

// A plain counted array evicted in the same program as the atomic ones.
function plainShrink(): int32 {
	const arr: Plain[] = [{ tag: 1 }, { tag: 2 }, { tag: 3 }];
	arr.setLength(2);
	return arr[0].tag + arr[1].tag;
}

function main(): int32 {
	const a = spliceOut();
	const b = spliceInPlace();
	const c = shrinkBySetLength();
	const d = shrinkByLengthAssign();
	const e = plainShrink();
	console.log(`spliceOut=${a} spliceIn=${b} setLength=${c} lengthAssign=${d} plain=${e}`);
	if (a != 3 || b != 12 || c != 4 || d != 7 || e != 3) { return 1; }
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
