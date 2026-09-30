// @stdout: 1 r0 3
// @exit: 0

import { Shelf, Rack, libItem, wrap, pairWith } from "./shelfLib";

interface Item { name: string; }

const s = new Shelf<Item>();
s.put("x", { name: "hi" });
const stored = s.read("x");
if (stored == null || stored.name != "hi") {
	throw new Error("generic method lost caller-owned payload");
}
const r = new Rack<Item>({ name: "r0" });
const wrapped = wrap<Item>({ name: "caller" });
if (wrapped[0].name != "caller" || pairWith<Item>({ name: "pair" }) != 2) {
	throw new Error("generic function lost caller identity or defining-module scope");
}
console.log(`${s.size()} ${r.slots[0].name} ${libItem()}`);
