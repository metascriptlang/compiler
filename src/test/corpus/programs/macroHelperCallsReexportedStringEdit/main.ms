// @stdout: a+b+c a*b-c ...a+b+c|a+b+c a*b-c ...a+b+c
// @exit: 0
// note: a macro calls helpers of another module that use replaceAll, replace and padStart, one through a second helper. The C prelude declares those in a shared module and re-exports them; the macro VM runs the Raiser variant the re-exporting module has, where it used to compile the shared body and stop at a byte finder with no Raiser tier.

import { Node, createNodeAt, NodeKind } from "std/meta";
import { plussed, firstStar, padded } from "./lib";

macro all(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: plussed("a-b-c") }, at.location);
}

macro first(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: firstStar("a-b-c") }, at.location);
}

macro pad(at: Node): Node {
	return createNodeAt(NodeKind.StringLiteral, { value: padded("a-b-c") }, at.location);
}

const atCompile = all(0) + " " + first(0) + " " + pad(0);
const atRun = plussed("a-b-c") + " " + firstStar("a-b-c") + " " + padded("a-b-c");
console.log(atCompile + "|" + atRun);
