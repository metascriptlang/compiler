// @stdout: 1 2 7 3 0 | 0 0 1 | 0 7 1 none
// note: an object literal gives every field whose type has no default value and leaves value, optional and nullable fields at their zero value; `new` of a class without a constructor runs its field initializers. Same output on C, JS and the Raiser.
class Item { v: int32 = 7; }
struct Holds { xs: int32[]; }

class Bag<T> {
	n: int32;
	items: T[];
	r: Item;
	f: () => int32;
	h: Holds;
	opt?: int32[];
	maybe: Item | null;
}

interface Shape { name: string; points: int32[]; w: int32; }

class Init {
	n: int32;
	items: int32[] = [];
	r: Item = new Item();
	f: () => int32 = (): int32 => 1;
	opt?: Item;
}

const b: Bag<string> = { n: 1, items: ["a", "b"], r: new Item(), f: (): int32 => 3, h: { xs: [] } };
const s: Shape = { name: "s", points: [] };
const i = new Init();
console.log(`${b.n} ${b.items.length} ${b.r.v} ${b.f()} ${b.h.xs.length} | ${s.points.length} ${s.w} ${b.opt == null && b.maybe == null ? 1 : 0} | ${i.items.length} ${i.r.v} ${i.f()} ${i.opt == null ? "none" : "some"}`);
