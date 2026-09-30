// @stdout: 1 r0 3 hi
// @exit: 0

import { Shelf, Rack, libItem, wrap, pairWith } from "./shelfLib";

interface Item { name: string; }

const s = new Shelf<Item>();
s.put("x", { name: "hi" });
const stored = s.read("x");
if (stored == null || stored.name != "hi") {
	throw new Error("generic method lost caller-owned payload");
}
const viaField = s.byName.get("x");
if (viaField == null) {
	throw new Error("field initializer map lost caller-owned payload");
}
const r = new Rack<Item>({ name: "r0" });
const wrapped = wrap<Item>({ name: "caller" });
if (wrapped[0].name != "caller" || pairWith<Item>({ name: "pair" }) != 2) {
	throw new Error("generic function lost caller identity or defining-module scope");
}
console.log(`${s.size()} ${r.slots[0].name} ${libItem()} ${viaField.name}`);
