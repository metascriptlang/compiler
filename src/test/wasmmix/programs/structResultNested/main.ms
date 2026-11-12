// @stdout: 3 4 | 11 21
// @stdout: true true
// @stdout: -9007199254740993 -7 2.5 true 4294967295
import { Pair, shift, viaCallback, maybe, wide } from "./structResultNestedWasm";

const inner: Pair[] = [];
const outer = viaCallback({ a: 1, b: 2 }, (n: int32): int32 => {
	inner.push(shift({ a: 10, b: 20 }, n));
	return 2;
});
console.log(`${outer.a} ${outer.b} | ${inner[0].a} ${inner[0].b}`);
const none = maybe({ a: 5, b: 6 }, false);
const some = maybe({ a: 5, b: 6 }, true);
console.log(`${none == null} ${some != null && some.a == 5 && some.b == 6}`);
const w = wide(7);
console.log(`${w.big} ${w.neg} ${w.ratio} ${w.on} ${w.top}`);
