// @stdout: param a none
// @stdout: test true false
// @stdout: iface 1 none
// @stdout: undef a none
// @stdout: tagged a s
// @stdout: local none x
// @stdout: field none y
// @stdout: maybe 1 none
// @stdout: generic d u
// note: a generic alias instance of an object type (`Id<User>` with `type Id<T> = T`) beside null, undefined or another member is the type it names, so `Id<User> | null` is `User | null`: before, the union kept the alias instance as its member, C lowered the parameter as a tagged union and failed clang, and JS folded `u === null` to false and read a field of null. Variants: class and interface, null and undefined, a tagged member beside string, a local, a field, a scalar payload (`Id<number> | null` into `number | null`) and a generic `Id<T> | null`.
type Id<T> = T;

class User {
	name: string;
	constructor(name: string) { this.name = name; }
}

interface Pt { x: number; }

class Slot {
	held: Id<User> | null = null;
}

function pick(u: Id<User> | null): string {
	if (u === null) return "none";
	return u.name;
}

function isNull(u: Id<User> | null): boolean {
	return u === null;
}

function pickPt(p: Id<Pt> | null): string {
	if (p === null) return "none";
	return `${p.x}`;
}

function pickUndef(u: Id<User> | undefined): string {
	if (u === undefined) return "none";
	return u.name;
}

function tagged(u: Id<User> | string): string {
	if (typeof u === "string") return u;
	return u.name;
}

function local(n: int32): string {
	let u: Id<User> | null = null;
	if (n > 0) u = new User("x");
	return u === null ? "none" : u.name;
}

function fieldOf(s: Slot): string {
	const u = s.held;
	return u === null ? "none" : u.name;
}

function maybe(v: Id<number> | null): string {
	const w: number | null = v;
	return w === null ? "none" : `${w}`;
}

function firstOr<T>(u: Id<T> | null, d: T): T {
	if (u === null) return d;
	return u;
}

console.log(`param ${pick(new User("a"))} ${pick(null)}`);
console.log(`test ${isNull(null)} ${isNull(new User("b"))}`);
console.log(`iface ${pickPt({ x: 1 })} ${pickPt(null)}`);
console.log(`undef ${pickUndef(new User("a"))} ${pickUndef(undefined)}`);
console.log(`tagged ${tagged(new User("a"))} ${tagged("s")}`);
console.log(`local ${local(0)} ${local(1)}`);
const filled = new Slot();
filled.held = new User("y");
console.log(`field ${fieldOf(new Slot())} ${fieldOf(filled)}`);
console.log(`maybe ${maybe(1)} ${maybe(null)}`);
const d = new User("d");
console.log(`generic ${firstOr<User>(null, d).name} ${firstOr<User>(new User("u"), d).name}`);
