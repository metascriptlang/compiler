// @stdout: 1 1 2
// note: number, float64 and an alias of number name one type, so a generic instantiated through each spelling is one instance; before, each spelling defined its own and C refused the duplicate.
class Box<T> { v: T[] = []; }

function sizeOf<K>(k: K): int32 {
	const b = new Box<K>();
	b.v.push(k);
	return b.v.length;
}

type Meters = number;
const a = sizeOf(2.5);
const n = new Box<number>();
n.v.push(1.5);
const m = new Box<Meters>();
m.v.push(2);
console.log(`${a} ${n.v.length} ${m.v[0]}`);
