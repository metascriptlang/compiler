// @stdout: 1 r0 3
// @exit: 0
// note: the lib declares its own private `Item` and generic classes over `T`; main instantiates them with its own `Item`. The instance bodies (a field initializer, a constructor, a method) are re-checked in the lib's scope, where `T` must stay bound to main's `Item` rather than be rewritten to the name `Item`, which the lib resolves to its own type (fixedbugs/bug565).

import { Shelf, Rack, libItem } from "./shelfLib";

interface Item { name: string; }

const s = new Shelf<Item>();
s.put("x", { name: "hi" });
const r = new Rack<Item>({ name: "r0" });
console.log(`${s.size()} ${r.slots[0].name} ${libItem()}`);
