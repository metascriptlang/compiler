// @stdout: 2 3 7 1 10|21
// @exit: 0
// note: a macro reading a checked body through `getImpl` sees each callee as the symbol it resolved to, so `getImpl(callee)` reads that declaration: an imported helper, a same-named helper from another module under an alias, the winning overload of a call, and an imported module constant. The callee used to arrive as a bare name and `getImpl` stopped the build with "node is not a symbol".

import { GAIN, scale } from "./gainA";
import { scale as scaleB } from "./gainB";
import { calleeNumbers } from "./inspect";

function pick(x: int32): int32 { return x + 7; }
function pick(x: float32): float32 { return x + 1.0; }

function frag(x: float32): float32 {
	return scale(x) + scaleB(x) + (pick(3) as float32) + pick(x) + GAIN;
}

const out: string[] = [];
out.push(calleeNumbers(frag));
out.push(String(frag(0.0) as int32));
console.log(out.join("|"));
