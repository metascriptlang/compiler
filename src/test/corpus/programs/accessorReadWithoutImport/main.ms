// @stdout: 3 5 boxed 3
// note: an accessor is a member of its class type, so `h.counter.value` resolves in a module that never imports the class's module; before, the read failed with "Property 'value' does not exist on type 'Counter'. Available: count" unless the reader imported `Counter`, because the accessor was found only through extension entries an import registers.
import { Holder } from "./holder";
import { Outer } from "./outer";

const h = new Holder();
const first = h.counter.value;
h.counter.value = 5;
const o = new Outer();
console.log(`${first} ${h.counter.value} ${h.box.inner} ${o.holder.counter.value}`);
