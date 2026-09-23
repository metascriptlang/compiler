// nim-guard: an array of atomic-rc cells releases its elements atomically
//
// INVARIANT: element ops come from the ELEMENT's type. The reference lifts a
//   seq's ops through fillBody(elemType) → atomicRefOp for a ref element; our
//   Ref elements collapse into the runtime msRefArray family, whose ops were
//   hardcoded plain, so an atomic-rc cell (born at MS_RC_INCREMENT) was never
//   released by the array's destroy or copy.
//
// WHAT IT PROTECTS: the counted and the inert msRefArray families share ONE
//   weak cell TypeInfo symbol, first-ensure-wins, so a program mixing families
//   scrambles the shared cell's destroyer. The atomic family therefore carries
//   its own cell name; this guard holds a plain interface array beside the
//   atomic ones in the SAME program so a regression there shows up as an
//   imbalance rather than as a silent wrong destroyer.
//
// RED MEANS the array arm stopped selecting by element type, or the atomic
//   family lost its own cell TypeInfo — run /trace-nim on classifyArray and on
//   refArrayDestroyFn / refArrayCellName before touching this file.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).
// GUARD-BALANCE TOTAL

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Pt { x: int32; }

interface Plain { tag: int32; }

function cells(): int32 {
	const arr: Locked<int32>[] = [new Locked(1), new Locked(2)];
	arr[0] = new Locked(10);
	let sum = 0;
	for (const c of arr) {
		lockedUpdate(c, (v: int32): int32 => v + 1);
		sum = sum + lockedRead(c, (v: int32): int32 => v);
	}
	return sum;
}

function arcs(): int32 {
	const arr: Arc<Pt>[] = [new Arc<Pt>({ x: 4 }), new Arc<Pt>({ x: 5 })];
	let sum = 0;
	for (const a of arr) { sum = sum + a.x; }
	return sum;
}

// A plain counted array in the same program as the atomic ones: the two
// families must not share one cell TypeInfo.
function plain(): int32 {
	const arr: Plain[] = [{ tag: 3 }, { tag: 4 }];
	let sum = 0;
	for (const p of arr) { sum = sum + p.tag; }
	return sum;
}

function main(): int32 {
	const c = cells();
	const a = arcs();
	const p = plain();
	console.log(`cells=${c} arcs=${a} plain=${p}`);
	if (c != 14 || a != 9 || p != 7) { return 1; }
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
