// @stdout: read=4 write=6 early=6 index=9 push=2 override=3 accessor=3 nested=5
// note: a member access the checker rewrites into a call that reads its receiver twice (a Proxy trap call `handler.get(proxyTarget(p), key)`, a compound write through a Proxy or through a setter) reads the receiver as narrowed by a null check both times. Before, the second read was a fresh copy with no place in the flow graph, typed as the declared `T | null`: C dereferenced the nullable holder with the wrong operator and a setter's compound write was refused; JS printed the right line. Same output on every backend.
interface User { name: int32; }

export class Traps {
	get<K extends keyof User>(target: User, key: K): User[K] { return Reflect.get(target, key); }
	set<K extends keyof User>(target: User, key: K, value: User[K]): boolean {
		return Reflect.set(target, key, value);
	}
}

export class ListTraps {
	get<T, K extends keyof T>(target: T, key: K): T[K] { return Reflect.get(target, key); }
	set<T, K extends keyof T>(target: T, key: K, value: T[K]): boolean { return Reflect.set(target, key, value); }
	reverse(target: int32[]): void { target.push(3); }
}

class Slot {
	p: Proxy<User, Traps>;
	list: Proxy<int32[], ListTraps>;
	constructor(p: Proxy<User, Traps>, list: Proxy<int32[], ListTraps>) { this.p = p; this.list = list; }
}

class Counter {
	private n: int32 = 1;
	get count(): int32 { return this.n; }
	set count(v: int32) { this.n = v; }
}

class Box { c: Counter = new Counter(); }

const u: User = { name: 4 };
const items: int32[] = [9];
const slots = new Map<string, Slot>();
slots.set("a", new Slot(new Proxy(u, new Traps()), new Proxy(items, new ListTraps())));

function early(key: string): string {
	const slot = slots.get(key);
	if (slot === null) { return "none"; }
	return `${slot.p.name}`;
}

function counted(make: boolean): Counter | null { return make ? new Counter() : null; }
function boxed(make: boolean): Box | null { return make ? new Box() : null; }

const out: string[] = [];
const slot = slots.get("a");
if (slot !== null) {
	out.push(`read=${slot.p.name}`);
	slot.p.name = 5;
	slot.p.name += 1;
	out.push(`write=${u.name}`);
	out.push(`early=${early("a")}`);
	out.push(`index=${slot.list[0]}`);
	slot.list.push(2);
	out.push(`push=${slot.list.length}`);
	slot.list.reverse();
	out.push(`override=${items.length}`);
}
const c = counted(true);
if (c !== null) {
	c.count += 2;
	out.push(`accessor=${c.count}`);
}
const b = boxed(true);
if (b !== null) {
	b.c.count += 4;
	out.push(`nested=${b.c.count}`);
}
console.log(out.join(" "));
