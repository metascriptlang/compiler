// @stdout: 1 2 7
// @exit: 0
// note: a compile-time converter applies where the RESOLVED slot type is its target type, never by the target's name. Two modules each declare a `Meters` and a converter for it; importing both is not a duplicate, and each JSX literal lowers through the converter of its own `Meters`. The local converter to `Seconds` is declared after the function that uses it, and `Seconds` after the converter: the target resolves with the declarations, before any body is checked. The two `Meters` used to be reported as one duplicate target, and the late converter to an alias was not found at all.

import { Node, NodeKind } from "std/meta";
import { Meters as FirstMeters, toFirstMeters } from "./first";
import { Meters as SecondMeters, toSecondMeters } from "./second";

function late(): Seconds {
	return <late/>;
}

converter toSeconds(n: Node): Seconds {
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: 7 };
}

type Seconds = number;

const a: FirstMeters = <first/>;
const b: SecondMeters = <second/>;
console.log(a.v.toString() + " " + b.v.toString() + " " + late().toString());
