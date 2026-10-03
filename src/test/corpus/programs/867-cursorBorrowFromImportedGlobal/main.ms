// @stdout: field 1 elem 1
// @xfail(raiser): the Raiser VM has no host function msStringSubstring
// note: a local that reads through a module-level variable exported by another module is an owned copy, never a borrow. A function of that module can replace the variable while the local is alive; the local used to borrow and read the freed object. Same-module sibling: 863-cursorBorrowFromGlobal.

import { Box, shared, sharedList, replaceShared, replaceFirst } from "./cursorGlobalLib";

function fieldOfImported(): string {
	const c = shared.child;
	replaceShared();
	const reuse = new Box(99);
	return "field " + String(c.n) + " " + String(reuse.n);
}

function elementOfImported(): string {
	const b = sharedList[0];
	replaceFirst();
	const reuse = new Box(98);
	return "elem " + String(b.n) + " " + String(reuse.n);
}

const a = fieldOfImported();
const b = elementOfImported();
console.log(a.substring(0, 7) + " " + b.substring(0, 6));
console.log(a);
console.log(b);
