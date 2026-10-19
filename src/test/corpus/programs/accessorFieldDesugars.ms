// Parity program — a TS auto-accessor `accessor x: T = init` is a hidden
// storage field plus a getter and a setter: reads, writes and `+=` go
// through them, for a value field and for a string field the class owns. A
// decorator on it runs with context kind "accessor" and the field's name, gets
// the generated getter and setter as `{ get, set }`, and may hand back a
// replacement setter and an initializer mutator, as TS's
// ClassAccessorDecoratorResult.
//
// @stdout: accessor:x | 1 3 13 ab! | 6 dirty=1 | 6.5 dirty=2
// @exit: 0

import { Node, NodeKind, ClassAccessorDecoratorContext, ClassAccessorDecoratorTarget, ClassAccessorDecoratorResult } from "std/meta";

let log = "";
function note(s: string): void { log = log + s + " "; }

macro paint(value: ClassAccessorDecoratorTarget, context: ClassAccessorDecoratorContext): ClassAccessorDecoratorResult {
	const at = value.set;
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: at.line, column: at.column,
		expr: { kind: NodeKind.CallExpr, line: at.line, column: at.column,
			callee: { kind: NodeKind.Identifier, line: at.line, column: at.column, name: "note" },
			arguments: [{ kind: NodeKind.StringLiteral, line: at.line, column: at.column, value: context.kind + ":" + context.name }] },
	});
	value.set.methodBody.statements.push({
		kind: NodeKind.ExprStmt, line: at.line, column: at.column,
		expr: { kind: NodeKind.CallExpr, line: at.line, column: at.column,
			callee: { kind: NodeKind.MemberExpr, line: at.line, column: at.column,
				object: { kind: NodeKind.Identifier, line: at.line, column: at.column, name: "this" },
				property: "markDirty", isOptional: false },
			arguments: [] },
	});
	return {
		set: value.set,
		init: (init: Node): Node => ({
			kind: NodeKind.BinaryExpr, line: init.line, column: init.column, operator: "*",
			left: init,
			right: { kind: NodeKind.NumberLiteral, line: init.line, column: init.column, value: 2.0, isFloat: true },
		}),
	};
}

class Counter {
	accessor n: int32 = 1;
	accessor label: string = "a";
}

class Box {
	dirty: int32 = 0;
	@paint accessor x: float32 = 1.5;
	markDirty(): void { this.dirty += 1; }
}

const c = new Counter();
const before = c.n;
c.n = 3;
const mid = c.n;
c.n += 10;
c.label += "b";
c.label = c.label + "!";

const b = new Box();
const start = b.x;
b.x = 6.0;
const afterSet = b.x;
const dirtyAfterSet = b.dirty;
b.x += 0.5;

console.log(log + "| " + String(before) + " " + String(mid) + " " + String(c.n) + " " + c.label
	+ " | " + String(afterSet) + " dirty=" + String(dirtyAfterSet)
	+ " | " + String(b.x) + " dirty=" + String(b.dirty) + (start == 3.0 ? "" : " start=" + String(start)));
