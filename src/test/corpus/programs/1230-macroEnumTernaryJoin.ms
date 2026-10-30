// @stdout: false true false false true true true
// note: a ternary of an enum-typed value and a member of that same enum has the enum's type, so comparing it with a member inside code a macro compiles lowers. Joined as `StmtKind.Block | StmtKind`, the union had no slot for the `StmtKind.Return` operand and the build threw. Variants: `==`, arms swapped, nested ternary, switch join, match join, an enum with explicit values.

import { Node, NodeKind } from "std/meta";

enum StmtKind { Block, Return, Expr }
enum Tag { A = 10, B = 20 }
class Stmt { kind: StmtKind = StmtKind.Block; tag: Tag = Tag.A; }

function opens(body: Stmt[]): boolean {
	const last = body.length > 0 ? body[body.length - 1].kind : StmtKind.Block;
	return last != StmtKind.Return;
}

function closes(body: Stmt[]): boolean {
	const last = body.length > 0 ? body[body.length - 1].kind : StmtKind.Block;
	return last == StmtKind.Return;
}

function swapped(body: Stmt[]): boolean {
	const last = body.length == 0 ? StmtKind.Block : body[body.length - 1].kind;
	return last == StmtKind.Return;
}

function nested(body: Stmt[]): boolean {
	const last = body.length > 1 ? body[0].kind : body.length > 0 ? StmtKind.Expr : StmtKind.Block;
	return last == StmtKind.Return;
}

function viaSwitch(body: Stmt[]): boolean {
	let last: StmtKind = StmtKind.Block;
	switch (body.length) {
		case 0: last = StmtKind.Block; break;
		default: last = body[0].kind;
	}
	return last == StmtKind.Return;
}

function viaMatch(body: Stmt[]): boolean {
	const last = match (body.length) {
		0 => StmtKind.Block,
		_ => body[0].kind,
	};
	return last == StmtKind.Return;
}

function taggedB(body: Stmt[]): boolean {
	const t = body.length > 0 ? body[0].tag : Tag.A;
	return t == Tag.B;
}

function ret(): Stmt[] {
	const s = new Stmt();
	s.kind = StmtKind.Return;
	return [s];
}

macro mOpens(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: opens(ret()) }; }
macro mCloses(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: closes(ret()) }; }
macro mSwapped(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: swapped([]) }; }
macro mNested(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: nested([]) }; }
macro mSwitch(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaSwitch(ret()) }; }
macro mMatch(): Node { return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: viaMatch(ret()) }; }
macro mTag(): Node {
	const s = new Stmt();
	s.tag = Tag.B;
	return { kind: NodeKind.BooleanLiteral, line: 1, column: 1, boolValue: taggedB([s]) };
}

console.log(`${mOpens()} ${mCloses()} ${mSwapped()} ${mNested()} ${mSwitch()} ${mMatch()} ${mTag()}`);
