// @stdout: init 7b | x 1 | 2 5 | first 2
// @xfail(raiser): the Raiser VM cannot evaluate std/core/struct.ms INITIAL_CAPACITY at comptime
import { Box } from "./box";

class Tagged<T> {
	tag: int32 = 7;
	w: T;
	constructor(w: T) { this.w = w; }
}

class Pair<K, V> {
	byKey: Map<K, V> = new Map<K, V>();
	count: int32 = 5;
	constructor(k: K, v: V) { this.byKey.set(k, v); }
}

class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}

const t = new Tagged<string>("b");
const s = new Box<string>("s");
s.add("x");
const p = new Pair<string, int32>("a", 1 as int32);
p.byKey.set("b", 2 as int32);
const bi = new Box<Item>(new Item("first"));
bi.add(new Item("a"));
bi.add(new Item("b"));
console.log(`${s.tag} ${t.tag}${t.w} | ${s.items[0]} ${s.items.length} | ${p.byKey.size} ${p.count} | ${bi.v.name} ${bi.items.length}`);
