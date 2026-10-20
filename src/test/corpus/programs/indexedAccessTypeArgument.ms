// @stdout: x 1 leaf object t 1
// note: an indexed access `T[K]` is a type argument after a callee (`new Box<T[K]>(…)`, `new Box<Box<T[K]>>(…)`, `isObject<T[K]>()`), and in a generic body it stays an indexed access in every instance, an array `T` read with a number `K` included (`as Box<T[K]>` is `Box<Todo>` for `T = Todo[]`). Before, the angles were read as comparisons, and the instance read `T[K]` as a sized array: "array size 'K' must be a compile-time integer constant". Same output on C, JS and the Raiser.
import { isObject } from "std/typetraits";

interface Pair { a: number; b: string; }
interface Todo { title: string; }
class Box<V> { v: V; constructor(v: V) { this.v = v; } }

function make<T, K extends keyof T>(t: T, k: K): Box<T[K]> {
	return new Box<T[K]>(Reflect.get(t, k));
}

function nest<T, K extends keyof T>(t: T, k: K): Box<Box<T[K]>> {
	return new Box<Box<T[K]>>(new Box<T[K]>(Reflect.get(t, k)));
}

function kind<T, K extends keyof T>(t: T, k: K): string {
	when (isObject<T[K]>()) {
		return "object";
	} else {
		return "leaf";
	}
}

function at<T, K extends keyof T>(t: T, k: K): T[K] {
	const found: unknown = new Box<T[K]>(Reflect.get(t, k));
	return (found as Box<T[K]>).v;
}

const p: Pair = { a: 1, b: "x" };
const todos: Todo[] = [{ title: "t" }];
console.log(`${make(p, "b").v} ${nest(p, "a").v.v} ${kind(p, "b")} ${kind(todos, 0)} ${at(todos, 0).title} ${at(todos, "length")}`);
