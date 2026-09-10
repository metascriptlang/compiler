// Decorators on a class declared inside a function body: class and member
// decorators rewrite the nested class where it is checked, initializer
// statements registered by a class decorator run in the enclosing body, and
// a dynamic bindSym from the decorator resolves the enclosing function's
// locals. Parity across every lane; no directive head needed.

import { Node, NodeKind, ClassDecoratorContext, ClassFieldDecoratorContext, bindSym, getTypeImpl } from "std/meta";

let hits: int32 = 0;

function bump(): void { hits = hits + 1; }

macro withExtra(value: Node, context: ClassDecoratorContext): Node {
	value.classBody.push({
		kind: NodeKind.PropertyDecl, line: value.line, column: value.column,
		propName: "extra", propType: "int32", propIsStatic: false, propIsReadonly: false,
		propVisibility: "public",
		propInitializer: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 42, isFloat: false },
	});
	return value;
}

macro twice(value: Node, context: ClassFieldDecoratorContext): Node {
	const init = value.propInitializer;
	value.propInitializer = {
		kind: NodeKind.BinaryExpr, line: value.line, column: value.column, operator: "*",
		left: init,
		right: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 2, isFloat: false },
	};
	return value;
}

macro counted(value: Node, context: ClassDecoratorContext): Node {
	context.addInitializer({
		kind: NodeKind.ExprStmt, line: value.line, column: value.column,
		expr: {
			kind: NodeKind.CallExpr, line: value.line, column: value.column,
			callee: { kind: NodeKind.Identifier, line: value.line, column: value.column, name: "bump" },
			args: [],
		},
	});
	return value;
}

macro seesLocal(value: Node, context: ClassDecoratorContext): Node {
	const s = bindSym("local" + "Count");
	if (s == null) error("localCount is not visible from the decorator", value);
	else {
		const t = getTypeImpl(s);
		if (t == null) error("localCount has no type", value);
		else if (t.kind != NodeKind.Identifier || t.name != "int32") error("localCount does not read as int32", value);
	}
	return value;
}

function makeExtra(): int32 {
	@withExtra
	class LocalA {
		base: int32 = 1;
	}
	const a = new LocalA();
	return a.base + a.extra;
}

function makeTwice(): int32 {
	class LocalB {
		@twice base: int32 = 21;
	}
	return new LocalB().base;
}

function makeCounted(): int32 {
	@counted
	class LocalC {
		base: int32 = 5;
	}
	return new LocalC().base;
}

function makeScoped(): int32 {
	const localCount: int32 = 3;
	@seesLocal
	class LocalD {
		base: int32 = 1;
	}
	return new LocalD().base + localCount;
}

class Outer {
	build(): int32 {
		@withExtra
		class LocalE {
			base: int32 = 3;
		}
		const e = new LocalE();
		return e.base + e.extra;
	}
}

const viaArrow = (): int32 => {
	@withExtra
	class LocalF {
		base: int32 = 7;
	}
	const f = new LocalF();
	return f.base + f.extra;
};

function main(): void {
	console.log(`extra=${makeExtra()}`);
	console.log(`twice=${makeTwice()}`);
	const first = makeCounted();
	const second = makeCounted();
	console.log(`counted=${first},${second} hits=${hits}`);
	console.log(`scoped=${makeScoped()}`);
	console.log(`method=${new Outer().build()}`);
	console.log(`arrow=${viaArrow()}`);
}
main();
