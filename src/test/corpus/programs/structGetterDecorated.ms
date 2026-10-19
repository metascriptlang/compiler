// Parity program — a decorator on a struct getter runs as on a class getter:
// context.kind is "getter", context.name the property name, the value is the
// getter routine, and a replacement or an edited body stays the struct's
// getter, read as `v.sum` without a call. Exported structs keep the same path.
//
// @stdout: getter:label 6 3 getter:area
// @exit: 0

import { Node, NodeKind, ClassGetterDecoratorContext } from "std/meta";

macro twice(value: Node, context: ClassGetterDecoratorContext): Node {
	const ret = value.fnBody.statements[0];
	ret.argument = {
		kind: NodeKind.BinaryExpr, line: ret.line, column: ret.column, operator: "*",
		left: ret.argument!,
		right: { kind: NodeKind.NumberLiteral, line: ret.line, column: ret.column, value: 2.0, isFloat: true },
	};
	return value;
}

macro named(value: Node, context: ClassGetterDecoratorContext): Node {
	const ret = value.fnBody.statements[0];
	ret.argument = { kind: NodeKind.StringLiteral, line: ret.line, column: ret.column, value: context.kind + ":" + context.name };
	return value;
}

macro keep(value: Node, context: ClassGetterDecoratorContext): void {}

struct V2 {
	x: float32;
	y: float32;
	@twice get sum(): float32 { return this.x + this.y; }
	@keep get first(): float32 { return this.x; }
	@named get label(): string { return ""; }
}

export struct Rect {
	w: float32;
	h: float32;
	@named get area(): string { return ""; }
}

const v: V2 = { x: 1.0, y: 2.0 };
const r: Rect = { w: 2.0, h: 3.0 };
console.log(v.label + " " + String(v.sum) + " " + String(v.first + 2.0) + " " + r.area);
