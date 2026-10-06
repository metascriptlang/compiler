// @stdout: items=4,5 pairs=a:1,bb:2 twice=8
// note: an extension written as `function*` makes its receiver iterable and an `async` extension awaits, on every backend; the routine's kind is read from its flags whatever other marks they carry (before, JS emitted `yield` inside a plain function and C left the async extension's body unlowered).
class Bag { items: int32[] = [4, 5]; }
function* toItems(this b: Bag): Iterator<int32> { for (const x of b.items) yield x; }
class Shelf { names: string[] = ["a", "bb"]; }
function* toPairs(this s: Shelf): Iterator<[string, int32]> {
	for (const n of s.names) yield [n, n.length];
}
async function twice(this b: Bag): Promise<int32> { return b.items[0] * 2; }

const items: string[] = [];
for (const x of new Bag()) items.push(x.toString());
const pairs: string[] = [];
for (const [k, v] of new Shelf()) pairs.push(k + ":" + v.toString());
const doubled = await new Bag().twice();
console.log("items=" + items.join(",") + " pairs=" + pairs.join(",") + " twice=" + doubled.toString());
