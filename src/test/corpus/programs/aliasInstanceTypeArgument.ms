// @stdout: box 1 2 3
// @stdout: iface 4
// @stdout: map 5 6
// @stdout: array 2 3
// @stdout: user z
// @stdout: generic 3
// note: a generic alias instance used as a type argument or an array element (`Box<Id<number>>`, `Id<number>[]` with `type Id<T> = T`) is the type it names, so it relates to `Box<number>` and `number[]` both ways and both spellings share one C type (strict pointer types hold): before, the checker refused every carrier, the array face claimed a memory layout difference, and accepted mixes emitted two C structs. Variants: a class and an interface carrier, a nested alias, `Map` and an array, an object argument and a generic `Id<T>[]`.
@passC("-Werror=incompatible-pointer-types");

type Id<T> = T;

class Box<V> {
	v: V;
	constructor(v: V) { this.v = v; }
	get(): V { return this.v; }
}

interface Cell<V> { v: V; }

class User {
	name: string;
	constructor(name: string) { this.name = name; }
}

function showCell(c: Cell<number>): number { return c.v; }

function sum(m: Map<string, number>): number {
	let t: number = 0;
	for (const [, v] of m) t = t + v;
	return t;
}

function unwrap<T>(xs: Id<T>[]): T[] { return xs; }

const a: Box<Id<number>> = new Box<number>(1);
const b: Box<number> = a;
const c = new Box<Id<number>>(2);
const d: Box<Id<Id<number>>> = new Box<number>(3);
const e: Box<number> = d;
console.log(`box ${b.get()} ${c.get()} ${e.get()}`);

const cell: Cell<Id<number>> = { v: 4 };
console.log(`iface ${showCell(cell)}`);

const m: Map<string, Id<number>> = new Map<string, number>();
m.set("k", 5);
const plain: Map<string, number> = m;
console.log(`map ${sum(plain)} ${(m.get("k") ?? 0) + 1}`);

const ids: Id<number>[] = [1, 2];
const nums: number[] = ids;
nums.push(3);
console.log(`array ${ids[1]} ${nums.length}`);

const bu: Box<Id<User>> = new Box<User>(new User("z"));
const bb: Box<User> = bu;
console.log(`user ${bb.v.name}`);

console.log(`generic ${unwrap<number>([1, 2, 3]).length}`);
