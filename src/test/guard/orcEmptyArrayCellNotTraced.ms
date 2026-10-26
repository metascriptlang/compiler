// nim-guard: the collector's trace of an owner does not push an empty array cell, so markGray,
// scan and collectColor never visit a cell that has no outgoing refs.
//
// Reference: a seq lives inline in its owner (lib/system/orc.nim nimTraceRef pushes only a
// non-nil ref slot), so an empty seq costs its owner's trace nothing; our array is a separate
// counted cell, and MS_TYPE_FLAG_ARRAY_CELL plus len == 0 in msOrcTraceRef is the same cost.
// C only: JS has no collector.
// Proven red with the flag absent from the cell TypeInfo: the trace pushes both slots (2).
//
// RED MEANS an array cell TypeInfo lost MS_TYPE_FLAG_ARRAY_CELL (codegen emitTypeInfoTable) or
// msOrcTraceRef stopped skipping a len-0 cell.

@compile("./fixtures/orcArrayCellTrace.c");

import { Handle } from "std/ffi";
import { msTestTracePushes } from "./fixtures/orcArrayCellTrace.h";

class Holder {
	empty: Holder[] = [];
	full: Holder[] = [];
}

const h = new Holder();
h.full.push(new Holder());
const handle = Handle.retain(h);
const pushed = msTestTracePushes(handle.ptr);
handle.release();
if (pushed !== 1) throw new Error(`owner trace pushed ${pushed} slots, expected 1 (the non-empty array cell only)`);
console.log("GUARD-OK");
