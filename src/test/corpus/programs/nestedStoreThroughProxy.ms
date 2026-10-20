// @stdout: store deep r0 3 deep a
// note: a nested store in the TypeScript shape: `Wrap<V>` is a conditional alias whose object branch is `Proxy<V, Deep<V>>`, and the handler class `Deep<T>` names `Wrap` back in its `get` return type. A read two levels deep (`p.a.b.c`), through an array field (`p.rows[0].name`), on a number leaf and on a call result each goes through the trap of the level it reads. Before, the alias instance met inside the handler kept no body, so the trap's return was refused and the Proxy read did not see through the alias. Same output on every backend.
import { isObject } from "std/typetraits";

interface C { c: string; }
interface B { b: C; }
interface Row { name: string; }
interface Root { a: B; rows: Row[]; n: number; }

type Wrap<V> = V extends string ? V : V extends number ? V : Proxy<V, Deep<V> >;

class Deep<T> {
	get<K extends keyof T>(target: T, key: K): Wrap<T[K]> {
		return wrap(Reflect.get(target, key));
	}
}

function wrap<V>(v: V): Wrap<V> {
	when (isObject<V>()) {
		const h: Deep<V> = new Deep();
		return new Proxy(v, h);
	} else {
		return v;
	}
}

interface User { name: string; }
type Leaf<V> = V extends string ? V : V extends number ? V : Proxy<V, Shallow<V> >;
class Shallow<T> {
	get<K extends keyof T>(target: T, key: K): Leaf<T[K]> {
		return Reflect.get(target, key) as Leaf<T[K]>;
	}
}
function user(u: User): Leaf<User> { const h: Shallow<User> = new Shallow(); return new Proxy(u, h); }

const root: Root = { a: { b: { c: "deep" } }, rows: [{ name: "r0" }], n: 3 };
const p = wrap(root);
console.log("store " + p.a.b.c + " " + p.rows[0].name + " " + p.n.toString() + " " + wrap(root).a.b.c + " " + user({ name: "a" }).name);
