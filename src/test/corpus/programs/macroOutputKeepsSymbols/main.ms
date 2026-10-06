// @stdout: 3 9\n11 4
// @exit: 0
// note: a node a macro hands back keeps the symbols the checker bound, as the reference keeps a typed node's symbols: a call keeps its winning overload, primary or not, and a parameter keeps the parameter it named, even where the expansion site declares another binding of the same name. These used to be resolved again by name where the macro put them.

import { Node } from "std/meta";

macro same(e: Node): Node { return e; }

function pick(x: int32): int32 { return x + 7; }
function pick(x: float32): float32 { return x + 1.0; }

function shadowed(x: int32): int32 {
	const y = same(x + 1);
	{
		const x = 100;
		return y + same(x - 100) * 0 + 0 * x;
	}
}

function plain(x: int32): int32 { return same(x) * 2; }

console.log(String(same(pick(2.0))), String(same(pick(2))));
console.log(String(shadowed(10)), String(plain(2)));
