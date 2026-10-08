// @stdout: f32 f32 f32|f32 f32 f32|f32 f32 f32|8
// @exit: 0
// note: `getImpl` hands a macro the checked body of a function declared further down the module, wherever the macro is called: at module level, inside a function and inside a nested function, and through a callee that is itself declared later. The body used to arrive unchecked before its declaration, so `getType` of its expressions stopped the build with "node has no type".

import { bodyKinds } from "./inspect";

const atModule = bodyKinds(frag);

function insideFunction(): string { return bodyKinds(frag); }

function outer(): string {
	function inner(): string { return bodyKinds(frag); }
	return inner();
}

function frag(x: float32): float32 { return later(x) + x; }
function later(x: float32): float32 { return x * 2.0 + 1.0; }

const out: string[] = [];
out.push(atModule);
out.push(insideFunction());
out.push(outer());
out.push(String(frag(2.666) as int32));
console.log(out.join("|"));
