// @ledger-balanced: Counter
// @stdout: 5 a
// @stdout: 12
// @stdout: 12
// @stdout: 3 b
// @stdout: 9 js
import { Handle } from "std/ffi";
import { Counter, total } from "./handleConstructWasm";

const h = Handle.retain(new Counter(5));
console.log(`${h.value().n} ${h.value().label}`);
console.log(`${h.value().bump(7)}`);
console.log(`${total(h)}`);

function make(n: int32): Handle<Counter> {
	return Handle.retain(new Counter(n, "b"));
}

const g = make(3);
console.log(`${g.value().n} ${g.value().label}`);
const local = new Counter(9, "js");
console.log(`${local.n} ${local.label}`);
g.release();
h.release();
