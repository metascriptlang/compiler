// nim-guard: a spread copy of a borrowed value keeps its ref members as views.
//
// INVARIANT (PARALOCK E24): `{...view}` and `[...view]` copy the container, not
//   what its ref fields and elements point at, so those members stay views: a
//   copy into a mutable slot is refused and a write through an inferred copy is E24.
//
// WHAT IT CATCHES: the spread reading the source's raw field and element types;
//   the pre-fix compiler let the task below write the borrowed `pair` and `cells`
//   through all three copies.
//
// RED MEANS: one of the three copies handed the task a mutable alias of shared state.
//
// GUARD-CHECK-FAIL field 'next' from the spread does not fit the literal's 'next'
// GUARD-CHECK-FAIL a spread copies its elements into the array as they are: 'Readonly<Cell>' is not assignable to 'Cell'
// GUARD-CHECK-FAIL cannot write through Readonly<Slot>

class Node { n: int32 = 0; }
class Cell { n: int32 = 0; }
class Slot { n: int32 = 0; }
interface Pair { n: int32; next: Node | null; }

function leak(w: Readonly<Pair>): Pair { return { ...w }; }

const pair: Pair = { n: 0, next: new Node() };
const cells: Cell[] = [new Cell()];
const slots: Slot[] = [new Slot()];
const f = spawn(() => {
	const copy = leak(pair);
	const mine: Cell[] = [...cells];
	const inferred = [...slots];
	inferred[0].n = 97;
	return copy.n + mine.length;
});
await f;
