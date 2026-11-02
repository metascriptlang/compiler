// A macro body decodes hex and base64 through std's shared codec, which is written as
// `when (c) { fast } else { portable }`: the macro VM runs the portable branch whatever backend builds.
//
// @stdout: hex=3 ab 0 ff|b64=3 1 2 3
// @exit: 0

import { Node, NodeKind } from "std/meta";

macro decodedAtCompileTime(at: Node): Node {
	const decoded = Buffer.fromString("ab00ff", "hex");
	const based = Buffer.fromString("AQID", "base64");
	const text = "hex=" + decoded.length.toString() + " " + decoded[0].toString(16) + " " + decoded[1].toString(16) + " " + decoded[2].toString(16)
		+ "|b64=" + based.length.toString() + " " + based[0].toString() + " " + based[1].toString() + " " + based[2].toString();
	return { kind: NodeKind.StringLiteral, line: at.line, column: at.column, value: text };
}

console.log(decodedAtCompileTime(0));
