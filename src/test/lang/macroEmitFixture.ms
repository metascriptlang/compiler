import { Node, NodeKind, createNodeAt, stringValue } from "std/meta";

function emitDeclaration(name: Node, text: string): Node {
	const code: Node = createNodeAt(NodeKind.StringLiteral, { value: text }, name.location);
	return createNodeAt(NodeKind.MacroInvocation, { macroName: "emit", macroArgs: [code], macroHasParens: true }, name.location);
}

export macro emitMarker(name: Node): Node {
	if (name.kind !== NodeKind.StringLiteral) { error("emitMarker takes a string literal", name); }
	return emitDeclaration(name, "static const int " + stringValue(name) + " = 1;");
}

export macro emitSpanMarker(name: Node): Node {
	if (name.kind !== NodeKind.StringLiteral) { error("emitSpanMarker takes a string literal", name); }
	function digits(bytes: Readonly<Span<uint8>>): string {
		let sum = 0;
		for (let i = 0; i < bytes.length; i += 1) sum += bytes[i] as int32;
		return sum.toString();
	}
	return emitDeclaration(name, ["static const int ", stringValue(name), " = ", digits(stringValue(name).asBytes()), ";"].join(""));
}

export macro plainOne(): Node {
	return { kind: NodeKind.NumberLiteral, line: 0, column: 0, value: 1, isFloat: false };
}

export function viaMacro<T>(x: T): int32 {
	return plainOne();
}
