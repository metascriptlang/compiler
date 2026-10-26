// nim-guard: the cycle collector's flag bits are not part of an owner's count: a cell marked
// maybe-cycle with no other owner is the last owner, and one with another owner is not.
//
// Reference: the count sits above `rcMask`, which covers every flag bit (lib/system/arc.nim:22-28),
// and the last-reference test masks it all (nimDecRefIsLastCyclicDyn / Static,
// lib/system/orc.nim ~590-621).
// Proven red with msOrcDecRefIsLast masking only the colour bits: a sole owner reads as not
// last and its count goes negative.
//
// RED MEANS msOrcDecRefIsLast in runtime/drc.h stopped masking with MS_RC_MASK; run /trace-ref
// on it against nimDecRefIsLastCyclicDyn.

@compile("./fixtures/orcMaybeCycleFlag.c");

import { msTestMaybeCycleSoleOwner, msTestMaybeCycleShared } from "./fixtures/orcMaybeCycleFlag.h";

const sole = msTestMaybeCycleSoleOwner();
if (sole !== 0) throw new Error(`sole owner with the maybe-cycle flag: code ${sole} (1 = not last, 2 = count changed)`);
const shared = msTestMaybeCycleShared();
if (shared !== 0) throw new Error(`shared cell with the maybe-cycle flag: code ${shared} (1 = last, 2 = flag or count wrong)`);
console.log("maybe-cycle flag is not count");
