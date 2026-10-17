import { Node, NodeKind, ClassFieldDecoratorContext, bindSym, getImpl, stringValue } from "std/meta";

export macro hasImpl(fn: Node): Node {
	const decl = getImpl(bindSym(fn.name));
	return { kind: NodeKind.NumberLiteral, line: fn.line, column: fn.column, value: decl === null ? 0 : 1, isFloat: false };
}

export macro typed(n: Node): Node {
	return quote { (${n} as int32) };
}

export macro twice(n: Node): Node {
	return quote { (${n} * 2) };
}

export macro same(n: Node): Node {
	return n;
}

export macro doubled(value: Node, context: ClassFieldDecoratorContext): Node {
	value.propInitializer = quote { (${value.propInitializer} * 2) };
	return value;
}

export macro hasImplNamed(name: Node): Node {
	const decl = getImpl(bindSym(stringValue(name)));
	return { kind: NodeKind.NumberLiteral, line: name.line, column: name.column, value: decl === null ? 0 : 1, isFloat: false };
}
