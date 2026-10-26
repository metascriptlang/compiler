// Parity program — a local alias of an indexed access whose field is nullable names a copy
// of that field's type. The alias renamed the field's own shared union, which then had a name
// and no declaring symbol, and the build threw while keying it.
//
// @stdout: true 5 n
// @stdout: 1 true
// @exit: 0

class Node { id: int32 = 0; next: Node | null = null; label: string | null = null; }
type Next = Node["next"];
type Label = Node["label"];
type Id = Node["id"];
interface Cell { u: { a: int32 } | null }
type Slot = Cell["u"];

function follow(n: Node): Next { return n.next; }
function tag(l: Label): string { return l == null ? "n" : l; }

const head = new Node();
const x: Next = null;
const id: Id = 5;
console.log(x == null, id, tag(head.label));
const cell: Cell = { u: { a: 1 } };
const slot: Slot = cell.u;
console.log(slot == null ? 0 : slot.a, follow(head) == null);
