// nim-guard: an rc operation of one family on a cell of the other family aborts under the ledger.
//
// INVARIANT: the family is chosen by the static ref type, never per cell, so a plain decref of an
//   Arc cell (or an atomic decref of a plain class) is a silent leak or a torn count. The Arc cell's
//   TypeInfo carries MS_TYPE_FLAG_ATOMIC and every rc helper checks it under -DMS_DRC_LEDGER
//   (runtime/drc.h MS_RC_FAMILY_CHECK).
// Proven red with the check removed from msDecRefIsLast: the plain decref of the Arc cell returned
//   normally instead of aborting.
//
// RED MEANS an rc helper lost its family check or the Arc cell TypeInfo lost MS_TYPE_FLAG_ATOMIC;
//   run /trace-ref on classifyArray, destructorLifting.ms refOp and codegen typeInfoFlags.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

@compile("./fixtures/rcFamily.c");

import { msTestPlainDecrefAborts, msTestAtomicDecrefAborts, msTestPlainTypedArcAllocAborts } from "./fixtures/rcFamily.h";

struct Pod { n: int32; }

class Plain { n: int32 = 0; }

function main(): void {
	const arc = new Arc<Pod>({ n: 1 });
	if (msTestPlainDecrefAborts(arc as Ptr<void>) != 1) throw new Error("a plain decref of an Arc cell did not abort");
	const plain = new Plain();
	if (msTestAtomicDecrefAborts(plain as Ptr<void>) != 1) throw new Error("an atomic decref of a plain class did not abort");
	if (msTestPlainTypedArcAllocAborts() != 1) throw new Error("msAllocArc with a plain TypeInfo did not abort");
	console.log("rc family mismatches abort");
}
main();
