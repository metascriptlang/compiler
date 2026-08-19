// nim-guard: a cursor field breaks a cycle declaratively
//
// INVARIANT (liftdestructors.nim:166 — a field carrying the cursor mark takes
//   defaultOp instead of fillBody, so it is absent from =destroy/=trace;
//   destructors.md:638 "With the cursor pragma one can break up cycles
//   declaratively"): a Cursor<T> slot does not participate in reference
//   counting, so a ring built out of cursor links carries no RC cycle and every
//   node dies under plain DRC — no cycle collector required.
//
// WHAT IT CATCHES: any drift that lets a cursor slot own its referent again —
//   the MemberExpr assignment fallback in inject.ms (lhsIsNonOwning), the
//   classify arm that returns noRcInfo, or the destructorLifting default that
//   keeps the field out of the generated hook. An owning cursor re-forms the
//   ring and CurRing starts leaking under drc.
//
// CONTROL: OwnRing is the same shape with an owning link. It leaks under drc BY
//   DESIGN (ARC does not collect cycles, exactly like Nim), so its balance is
//   asserted under orc only. Both red under orc = the cycle collector broke, not
//   the cursor rule; CurRing red under drc alone = the cursor rule went blind.
//
// RED MEANS: the cursor model drifted from Nim. Run /trace-nim on classifyType,
//   sinkClassify, and the MemberExpr arm of processAssignment.
// GUARD-BALANCE CurRing
// GUARD-BALANCE-ORC OwnRing

interface CurRing { tag: string; next: Cursor<CurRing>; }
interface OwnRing { tag: string; next: OwnRing | null; }

function main(): void {
	let i = 0;
	while (i < 5000) {
		const a: CurRing = { tag: "a", next: null as unknown as CurRing };
		const b: CurRing = { tag: "b", next: null as unknown as CurRing };
		a.next = b;
		b.next = a;

		const x: OwnRing = { tag: "x", next: null };
		const y: OwnRing = { tag: "y", next: null };
		x.next = y;
		y.next = x;

		i = i + 1;
	}
	console.log("done", i);
}

main();
