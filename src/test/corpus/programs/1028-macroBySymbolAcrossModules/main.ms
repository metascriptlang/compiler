// @stdout: 1 2 2 2 1 2 7
// @exit: 0
// note: a macro invocation expands the declaration of the symbol its name resolves to. Two modules declare a macro `pick`; this one imports the first by its name and the second under an alias through a star re-export hub and through a named re-export hub, and calls the aliased one from a generic body that only expands once instantiated. The star hub used to hand importers a macro symbol with no body, so the call reached codegen unlowered.

import { pick } from "./first";
import { pick as pickStar } from "./starHub";
import { pick as pickNamed } from "./namedHub";
import { Node as UserNode } from "./node";
import { foreignFirst, foreignSecond } from "./foreignConsumer";

function userValue(node: UserNode): int32 { return node.value; }

function viaGeneric<T>(v: T): number {
	return pickStar(v);
}

const a: number = pick(0);
const b: number = pickStar(0);
const c: number = viaGeneric<string>("s");
const d: number = pickNamed(0);
const user = new UserNode(7);
pick(0);
console.log(a.toString() + " " + b.toString() + " " + c.toString() + " " + d.toString()
	+ " " + foreignFirst().toString() + " " + foreignSecond().toString() + " " + userValue(user).toString());
