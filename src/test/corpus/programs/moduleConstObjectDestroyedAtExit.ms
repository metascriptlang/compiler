// @stdout: 6 b1 8 y3 1 2

interface Cfg { name: string; n: int32; on: () => int32; }
type Alias = Cfg;
interface Box<T> { v: T; name: string; }
class Item { n: int32 = 1; }
function zero(): int32 { return 0; }
function counter(start: int32): () => int32 {
	let n = start;
	return (): int32 => {
		n += 1;
		return n;
	};
}
const cfg: Cfg = { name: "a", n: 1, on: zero };
const viaAlias: Alias = { name: "a", n: 2, on: zero };
const boxed: Box<int32> = { v: 3, name: "x" };
export const items: Item[] = [];
const named: Alias[] = [];
cfg.on = counter(5);
cfg.name = "b" + cfg.n.toString();
viaAlias.on = counter(7);
boxed.name = "y" + boxed.v.toString();
items.push(new Item());
named.push({ name: "c", n: 4, on: counter(1) });
console.log(`${cfg.on()} ${cfg.name} ${viaAlias.on()} ${boxed.name} ${items.length} ${named[0].on()}`);
