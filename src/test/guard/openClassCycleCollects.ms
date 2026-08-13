// nim-guard: open-class cycle collection — the Nim tfFinal rule (row 70)
//
// INVARIANT (reference types.nim:436-438 `if tfFinal notin t.flags: result = true`):
//   a class that is extended (non-final) can form a reference cycle through a
//   base-typed field, because that field may point at a subclass that closes a
//   back-edge. canFormAcycle must return true for it so ORC installs cycle
//   collection — otherwise the cycle leaks (alloc > destroy at exit).
//
// WHAT IT CATCHES:
//   - a revert of the OpenClass bit (resolvePass) or the Struct-arm check
//     (cycles.ms cfaAux) — CChild leaks under orc again.
//
// CONTROL: DirectCycle is a self-referential base class (no subclass). Its cycle
//   is detected by the EXISTING back-edge walk already, so it collects under orc
//   even WITHOUT the OpenClass fix. If DirectCycle ever goes red while CChild is
//   red too, ORC itself broke — not the oracle. If only CChild is red, the
//   non-final oracle went blind. Keeping the control inline makes the two
//   failures distinguishable (NIM-REF row 70 landmine).
//
// DRC is NOT asserted: ARC/DRC does not collect cycles by design (same as Nim
//   ARC) — the CChild cycle leaks under drc forever and that is correct.
//
// RED MEANS: the open-class canFormAcycle rule drifted from the Nim tfFinal model.
//   Run /trace-nim on canFormAcycleAux (types.nim:408-461).
// GUARD-BALANCE-ORC CChild
// GUARD-BALANCE-ORC DirectCycle

class CBase { tag: string }
class CChild extends CBase { link: CBase | null = null }
class DirectCycle { link: DirectCycle | null = null }

let i = 0;
while (i < 5000) {
	const a = new CChild();
	const b = new CChild();
	a.link = b;
	b.link = a;
	const x = new DirectCycle();
	const y = new DirectCycle();
	x.link = y;
	y.link = x;
	i = i + 1;
}
console.log("done", i);
