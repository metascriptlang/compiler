// nim-guard: an atomic-rc cell reached through a nullable slot is released atomically
//
// INVARIANT: every retain and release of a cell whose refcount is atomic
//   (`Locked<T>`, `Arc<T>`) uses the atomic op, at EVERY site that picks an op
//   by type. The reference picks field and element ops from the field's own
//   type (liftdestructors fillBody → atomicRefOp for tyRef); ours lowers
//   `Ref<T> | null` to a bare `T*`, so the union arm has to ask the INNER type
//   whether the cell is atomic. Both arms used to ask the union itself, which
//   is never a Ref, so the answer was always "plain".
// NIM-REF AN-* (classify union arm) and TR-* (destructorLifting union field).
//
// WHAT IT PROTECTS: a cell is born at MS_RC_INCREMENT (the atomic convention),
//   so a plain msDecref never reaches "last" and the cell is never freed. The
//   leak is invisible without the ledger: the program prints the right values.
//
// RED MEANS the union arm stopped selecting by the inner type — run /trace-nim
//   on classify's Union arm and destructorLifting's Union field arm before
//   touching this file.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).
// GUARD-BALANCE TOTAL

import { lockedUpdate, lockedRead } from "std/core/promise";

struct Pt { x: int32; }

interface Holder { cell: Locked<int32> | null; }

interface Box { pt: Arc<Pt> | null; }

function throughField(): int32 {
	const h: Holder = { cell: new Locked(7) };
	const c = h.cell;
	if (c == null) { return -1; }
	lockedUpdate(c, (v: int32): int32 => v + 1);
	return lockedRead(c, (v: int32): int32 => v);
}

function throughLocal(): int32 {
	const c: Locked<int32> | null = new Locked(20);
	if (c == null) { return -1; }
	return lockedRead(c, (v: int32): int32 => v + 1);
}

function arcThroughField(): int32 {
	const a: Arc<Pt> = new Arc<Pt>({ x: 5 });
	const b: Box = { pt: a };
	const p = b.pt;
	if (p == null) { return -1; }
	return p.x;
}

function main(): int32 {
	const field = throughField();
	const local = throughLocal();
	const arc = arcThroughField();
	console.log(`field=${field} local=${local} arc=${arc}`);
	if (field != 8 || local != 21 || arc != 5) { return 1; }
	return 0;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
