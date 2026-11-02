// nim-guard: a collection key's hash or == declared over the mutable type is refused on every backend.
//
// INVARIANT (PARALOCK E24): a Map or Set probes its keys through Readonly<K>, so the key's
//   `hash` and `==` must accept the view, exactly as a table's key parameter is read-only
//   and a hash over a mutable key does not bind there.
//
// WHAT IT CATCHES: the pre-fix compiler refused these keys only inside the C collection
//   body, while JS bound the mutable-receiver ops at `new` and ran the program.
//
// RED MEANS: one backend accepts a key whose ops could mutate the key while the table probes it.
//
// GUARD-JS
// GUARD-CHECK-FAIL 'Line' cannot be a Map key: the Map hashes a key through Readonly<Line>
// GUARD-CHECK-FAIL 'Line' cannot be a Set key: the Set hashes a key through Readonly<Line>
// GUARD-CHECK-FAIL 'Cell' cannot be a Map key: the Map compares keys through Readonly<Cell>

struct Line { text: string; runs: Vec<int32>; }
function hash(this l: Line): int64 { return l.text.length as int64; }

struct Cell { text: string; runs: Vec<int32>; }
function hash(this c: Readonly<Cell>): int64 { return c.text.length as int64; }
function `==`(a: Cell, b: Cell): boolean { return a.text == b.text; }

const m = new Map<Line, int32>(); // GUARD-REFUSED
const s = new Set<Line>(); // GUARD-REFUSED
const c = new Map<Cell, int32>(); // GUARD-REFUSED
m.set({ text: "a", runs: [] }, 1);
s.add({ text: "a", runs: [] });
c.set({ text: "a", runs: [] }, 1);
console.log(`GUARD-OK ${m.size} ${s.size} ${c.size}`);
