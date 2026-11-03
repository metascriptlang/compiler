// @stdout: t3b u3 s7xyz
// @stdout: t3b u3 s7xyz
// @exit: 0
// note: macro helpers copy a generic struct with a string field and a struct nesting it with an array field out of a class's arrays at comptime, after a helper whose lowering the engine refused (it pops a string array) had already lifted the copy hooks of both types. The engine compiles each lifted hook it calls from the hook's own lowered body; before, the hook lived only in the refused program and the macro stopped with "cannot evaluate 'Pair…Copy' at comptime: symbol kind is Function".
import { Node, NodeKind } from "std/meta";
import { popsAndCopies, copiesPair, copiesNestedSlot } from "./lib";

macro popped(): Node {
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: popsAndCopies(3) };
}

macro pairCopy(): Node {
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: copiesPair(3) };
}

macro slotCopy(): Node {
	return { kind: NodeKind.StringLiteral, line: 0, column: 0, value: copiesNestedSlot(7) };
}

console.log(popped() + " " + pairCopy() + " " + slotCopy());
console.log(popsAndCopies(3) + " " + copiesPair(3) + " " + copiesNestedSlot(7));
