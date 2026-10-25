// @stdout: proxy=b param=c generic=d ret=e field=f elem=g shape=7 indexed=h
// note: an object literal whose expected type is a generic alias instance (`At<T, K> = T[K]`, `Id<T> = T`, an alias of an object type) is built as the type the alias names, so a literal of an interface or object type is allocated on the heap like one written against the interface itself. Before, the literal kept the alias instance as its type and C built it as a stack value through a pointer (`tmp.name` on a `User*`); JS printed the right line. Same output on every backend.
type At<T, K extends keyof T> = T[K];
type Id<T> = T;
type Shape = { w: int32; };

interface User { name: string; }
interface Root { user: User; }

export class Traps<T> {
	get<K extends keyof T>(target: T, key: K): T[K] { return Reflect.get(target, key); }
	set<K extends keyof T>(target: T, key: K, value: At<T, K>): boolean {
		return Reflect.set(target, key, value);
	}
}

function nameOf(u: Id<User>): string { return u.name; }
function pass<T>(v: Id<T>): T { return v; }
function made(): Id<User> { return { name: "e" }; }
function width(s: Id<Shape>): int32 { return s.w; }
function put<T, K extends keyof T>(target: T, key: K, value: At<T, K>): void { target[key] = value; }

class Holder { u: Id<User> = { name: "f" }; }

const p = new Proxy<Root, Traps<Root> >({ user: { name: "a" } }, new Traps<Root>());
p.user = { name: "b" };
const elems: Id<User>[] = [{ name: "g" }];
const root: Root = { user: { name: "a" } };
put(root, "user", { name: "h" });
const out = [
	`proxy=${p.user.name}`,
	`param=${nameOf({ name: "c" })}`,
	`generic=${pass<User>({ name: "d" }).name}`,
	`ret=${made().name}`,
	`field=${new Holder().u.name}`,
	`elem=${elems[0].name}`,
	`shape=${width({ w: 7 })}`,
	`indexed=${root.user.name}`,
];
console.log(out.join(" "));
