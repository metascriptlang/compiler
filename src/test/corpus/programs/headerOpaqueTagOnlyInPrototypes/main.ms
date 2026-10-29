// @xfail(raiser): raiser runtime error: Unknown host function: nodeVal
// Parity program — a struct or union tag that its header only mentions inside prototypes is one
// type in the importer's C too, so a function of the importer that names the tag takes the handle
// the header returns.
// Axes: a struct and a union tag, each first mentioned in a return type and in a parameter, and
// named in the importer's own function signatures, with no header and no typedef declaring either
// tag. The two-header case is headerOpaqueTagSharedAcrossHeaders.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 4 5
// @exit: 0

import { nodeNew, nodeVal, numNew, numVal, Node, Num } from "./proto.h";

function readNode(n: Ptr<Node>): int32 {
	return nodeVal(n);
}

function readNum(n: Ptr<Num>): int32 {
	return numVal(n);
}

console.log(`${readNode(nodeNew(4)!)} ${readNum(numNew(5)!)}`);
