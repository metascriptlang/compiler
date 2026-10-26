// A C pointer-to-pointer or pointer to a typedef'd scalar keeps its C pointee in the emitted
// call: `char **` (null, or the address of a `cchar` pointer variable), `size_t *`, `const char **` and `struct S **`
// each pass the imported type, so a strict C compiler (gcc 15) sees the exact prototype.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 7,8,pointee|2,2|5
// @stdout: 42,42
// @stdout: line=6
// @exit: 0

import {
	pointeeFill, pointeeGetline, strtol, pointeeList, pointeeNames, pointeeNode, pointeeNodeValue, pointeeNodeFree,
	size_t, cchar, Pointee0Node,
} from "./pointee.h";

let text: Ptr<cchar>;
let cap: size_t = 0;
const used = pointeeFill(text, cap);
const names = pointeeList();
let count: size_t = 0;
const len = pointeeNames(names, count);
let node: Ptr<Pointee0Node>;
pointeeNode(node);
console.log(`${used},${cap},${text as cstring}|${count},${len}|${pointeeNodeValue(node)}`);
pointeeNodeFree(node);

const digits = "42abc";
let end: Ptr<cchar>;
console.log(`${strtol(digits, null, 10)},${strtol(digits, end, 10)}`);

let buf: Ptr<cchar>;
let room: size_t = 0;
const read = pointeeGetline(buf, room);
console.log(`line=${read}`);
