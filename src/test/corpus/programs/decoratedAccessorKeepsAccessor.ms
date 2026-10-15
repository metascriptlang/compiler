// Parity program — a decorator on a class getter or setter runs with the TS
// context kind ("getter" / "setter") and the accessor's own name, and the
// accessor still serves reads and writes afterwards: handed back unchanged, or
// replaced by a getter or setter with a new body.
//
// @stdout: getter:x setter:x 6 2 102 14
// @exit: 0

import { Node, NodeKind, ClassGetterDecoratorContext, ClassSetterDecoratorContext } from "std/meta";

let log = "";
function note(s: string): void { log = log + s + " "; }

macro tell(value: Node, context: ClassGetterDecoratorContext): Node {
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: { kind: NodeKind.CallExpr, line: value.line, column: value.column,
			callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "note" },
			arguments: [{ kind: NodeKind.StringLiteral, line: value.line, column: value.column, value: context.kind + ":" + context.name }] },
	});
	return value;
}

macro plus100(value: Node, context: ClassGetterDecoratorContext): Node {
	value.methodBody = { kind: NodeKind.BlockStmt, line: value.line, column: value.column, statements: [
		{ kind: NodeKind.ReturnStmt, line: value.line, column: value.column, argument: {
			kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "+",
			left: { kind: NodeKind.MemberExpr, line: value.line, column: value.column,
				object: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "this" },
				property: "_y", isOptional: false },
			right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 100, isFloat: false } } },
	] };
	return value;
}

macro storeTwice(value: Node, context: ClassSetterDecoratorContext): Node {
	const v: Node = { kind: NodeKind.Identifier, line: value.line, column: value.column, name: value.methodParams[0] };
	value.methodBody = { kind: NodeKind.BlockStmt, line: value.line, column: value.column, statements: [
		{ kind: NodeKind.ExprStmt, line: value.line, column: value.column, expr: {
			kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "=",
			left: { kind: NodeKind.MemberExpr, line: value.line, column: value.column,
				object: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "this" },
				property: "_w", isOptional: false },
			right: { kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "*",
				left: v,
				right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 2, isFloat: false } } } },
	] };
	return value;
}

class P {
	private _x: int32 = 1;
	private _y: int32 = 2;
	private _w: int32 = 0;
	@tell get x(): int32 { return this._x; }
	@tell set x(v: int32) { this._x = v; }
	get y(): int32 { return this._y; }
	@plus100 get z(): int32 { return 0; }
	get w(): int32 { return this._w; }
	@storeTwice set w(v: int32) { this._w = v; }
}

const p = new P();
p.x = p.x + 5;
p.w = 7;
console.log(log + String(p.x) + " " + String(p.y) + " " + String(p.z) + " " + String(p.w));
