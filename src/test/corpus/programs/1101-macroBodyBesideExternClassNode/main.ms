// @stdout: true
// @exit: 0
// note: the calling module declares an extern class Node. The macro body's Node is std/meta's, resolved in the declaring module: reading its kind used to fail with "Property 'kind' does not exist on type 'Node'" naming the caller's fields.

import { kindNumber, numberKind } from "./decl";

extern class Node {
	tagName: string;
}

const kind: number = kindNumber(7);
console.log((kind == numberKind).toString());
