// @stdout: 5 5 | 7 9 | 1 | true
// @xfail(raiser): the Raiser VM stops with 'attempt to access a nil address'
class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
interface Crate<T> { v: T; }

function mk<T>(): T[] {
	const out: T[] = [];
	return out;
}

const inner = new Box<int32>(5 as int32);
const two = new Box<Box<int32>>(inner);
const three = new Box<Box<Box<int32>>>(two);
const crates = new Map<string, Crate<int32>>();
crates.set("a", { v: 7 as int32 });
const made = mk<Crate<int32>>();
made.push({ v: 9 as int32 });
const lo: int32 = 1;
const hi: int32 = 64;
const by: int32 = 2;
const shifted = lo < hi >> (by);
console.log(`${two.v.v} ${three.v.v.v} | ${crates.get("a")!.v} ${made[0].v} | ${crates.size} | ${shifted}`);
