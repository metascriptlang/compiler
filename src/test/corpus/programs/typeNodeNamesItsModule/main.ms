// @stdout: Own@main.ms LibS@lib.ms Own@main.ms Own@main.ms Tree@main.ms Tree@main.ms|Own@main.ms LibS@lib.ms
import { Node, NodeKind, getType, getTypeImpl } from "std/meta";
import { LibS } from "./lib";

struct Own {
	y: float32;
}

struct Holder {
	own: Own;
	lib: LibS;
}

struct Tree {
	kids: Tree[];
	tag: int32;
}

function f(a: Own, b: LibS, h: Holder, xs: Own[], t: Tree): int32 { return b.v + h.lib.v + xs.length as int32 + t.tag + (a.y as int32); }

function named(n: Node | null): string {
	if (n == null) return "no node";
	if (n.resolvedSym == null) return "null";
	const path = n.resolvedSym.modulePath;
	return n.resolvedSym.name + "@" + path.substring(path.lastIndexOf("/") + 1);
}

macro probe(e: Node): Node {
	const ps = getType(e).typExprParams;
	const text = [
		named(ps[0]), named(ps[1]), named(ps[2].typExprFieldTypes[0]), named(ps[3].typExprArgs[0].typExprElement),
		named(ps[4]), named(ps[4].typExprFieldTypes[0].typExprArgs[0].typExprElement),
	].join(" ") + "|" + named(getTypeImpl(ps[0])) + " " + named(getTypeImpl(ps[1]));
	return { kind: NodeKind.StringLiteral, line: e.line, column: e.column, value: text };
}

console.log(probe(f));
