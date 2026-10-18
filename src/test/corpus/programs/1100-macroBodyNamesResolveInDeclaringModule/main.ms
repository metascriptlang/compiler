// @stdout: 5 true
// @exit: 0
// note: a macro body names std/meta's Node, NodeKind and DeclKind; those names resolve in the module that declares the macro, whatever the calling module declares. This caller declares its own class Node and enums NodeKind and DeclKind, and a nested helper returning Node | null used to fail with "Type 'NodeKind' is not assignable to type 'NodeKind'" because the engine took the caller's same-named symbols first.

import { keepNumber, nodeKindNumber, numberKind } from "./decl";

class Node {
	x: number = 0;
}

enum NodeKind { Group, Mesh, Light }
enum DeclKind { Alpha, Beta }

const answer: number = keepNumber(5);
const kind: number = nodeKindNumber(7);
const mine = new Node();
console.log(answer.toString() + " " + (kind == numberKind && mine.x == 0).toString());
