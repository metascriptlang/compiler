// @stdout: recursive true false
// @exit: 0

import { Node, NodeKind, getType, sameType } from "std/meta";
import { link as leftLink } from "./left";
import { link as rightLink, different } from "./right";

macro equalType(a: Node, b: Node): Node {
	return { kind: NodeKind.BooleanLiteral, boolValue: sameType(getType(a), getType(b)) };
}

const first = leftLink();
const second = rightLink();
const other = different();
console.log("recursive", equalType(first, second), equalType(first, other));
