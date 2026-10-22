// @stdout: element x x
// note: an element of a call result keeps its recursive alias. `Wrap<V>` is a conditional alias whose object branch is `Proxy<V, Deep<V>>`, and the handler class names `Wrap` back in `get` and `all`. `all` returns `Wrap<T[K]>[]`, so the alias instance is nested in an array: the call result's element must still carry its body, or `xs[0].b` cannot see through the Proxy. Same output on every backend.
import { isObject } from "std/typetraits";

interface B { b: string; }
interface Root { a: B; }

type Wrap<V> = V extends string ? V : Proxy<V, Deep<V> >;

class Deep<T> {
	get<K extends keyof T>(target: T, key: K): Wrap<T[K]> {
		return wrap(Reflect.get(target, key));
	}
	all<K extends keyof T>(target: T, key: K): Wrap<T[K]>[] {
		return [wrap(Reflect.get(target, key))];
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

const root: Root = { a: { b: "x" } };
const d: Deep<Root> = new Deep();
const xs = d.all(root, "a");
console.log("element " + xs[0].b + " " + wrap(root).a.b);
