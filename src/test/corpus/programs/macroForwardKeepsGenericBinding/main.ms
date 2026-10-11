// @stdout: 4 5 6 7
// @exit: 0
// note: a macro wraps the call it was given in a scope that declares a local of the callee's name. The forwarded call still calls the generic it named, with the type argument written or inferred, through an alias of an imported generic too. A forwarded call with explicit type arguments used to be looked up again by name and called the macro's local, printing 99.

import { Node } from "std/meta";
import { pick as choose } from "./pick";

macro shadowPick(call: Node): Node {
	return quote { ((): int32 => { const pick = (v: int32): int32 => 99; return ${call}; })() };
}

macro shadowChoose(call: Node): Node {
	return quote { ((): int32 => { const choose = (v: int32): int32 => 99; return ${call}; })() };
}

function pick<T>(value: T): T { return value; }

console.log(`${shadowPick(pick<int32>(4))} ${shadowPick(pick(5))} ${shadowChoose(choose<int32>(6))} ${shadowChoose(choose(7))}`);
