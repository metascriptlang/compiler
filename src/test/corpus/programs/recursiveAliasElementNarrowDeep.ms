// @stdout: narrow x none
// note: recursiveAliasElementRead one data level deeper, with a nullable alias `Opt<V> = ... Proxy<V, Deep<V>> | null`. The element of `some`'s `Opt<T[K]>[]` must keep its body so `x != null` narrows to the Proxy and `x.c` reads through its trap. Same output on every backend.
import { isObject } from "std/typetraits";

interface C { c: string; }
interface B { b: C; }
interface Root { a: B; }

type Opt<V> = V extends string ? V : Proxy<V, Deep<V> > | null;

class Deep<T> {
	get<K extends keyof T>(target: T, key: K): Opt<T[K]> {
		return wrap(Reflect.get(target, key));
	}
	some<K extends keyof T>(target: T, key: K): Opt<T[K]>[] {
		return [wrap(Reflect.get(target, key)), null];
	}
}

function wrap<V>(v: V): Opt<V> {
	when (isObject<V>()) {
		const h: Deep<V> = new Deep();
		return new Proxy(v, h);
	} else {
		return v;
	}
}

const root: Root = { a: { b: { c: "x" } } };
const db: Deep<B> = new Deep();
const xs = db.some(root.a, "b");
const x = xs[0];
const y = xs[1];
console.log("narrow " + (x != null ? x.c : "none") + " " + (y != null ? y.c : "none"));
