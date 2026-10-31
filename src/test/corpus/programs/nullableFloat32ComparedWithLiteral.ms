// @stdout: true true true false
// @stdout: true true true true
// @stdout: true true false
function same(a: float32, b: float32): boolean { return a === b; }

const rest: float32 = 0.2;
const maybe: float32 | null = rest;
const wide: float32 | string | null = rest;
const K = 0.2;
console.log(same(rest, 0.2), maybe === 0.2, 0.2 === maybe, maybe !== 0.2);
console.log(maybe === K, K === maybe, wide === 0.2, 0.2 === wide);

const none: float32 | null = null;
console.log(maybe == 0.2, 0.2 == maybe, none === 0.2);
