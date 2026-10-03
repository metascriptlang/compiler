// @stdout: 3 2 4 7
// note: aliases that recurse through an object type, an interface, a class or a named union are accepted and run; only a cycle through tuple, function, array, reference or distinct alone is refused at the declaration.
type Json = string | number | Json[];
type Tree = { v: number, kids: Tree[] };
interface Item { next: Item | null; v: number }
type Pair = [number, Item];
class Link { v: number = 4; next: Link | null = null }

const j: Json = [1, "a", [2]];
const t: Tree = { v: 1, kids: [{ v: 2, kids: [] }, { v: 3, kids: [] }] };
const p: Pair = [7, { next: null, v: 7 }];
const l = new Link();
console.log(`${(j as Json[]).length} ${t.kids.length} ${l.v} ${p[1].v}`);
