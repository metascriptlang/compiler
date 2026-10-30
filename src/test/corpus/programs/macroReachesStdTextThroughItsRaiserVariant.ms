// A macro that runs a std process capture reaches the text decoder, whose C body casts byte pointers the Raiser VM refuses; the VM takes the Raiser variant of that std module instead.
// @stdout: 3 3
// @skip-js

import { Node, NodeKind } from "std/meta";
import { execFileResult } from "std/process";

macro outputLength(): Node {
	const r = execFileResult("/bin/sh", ["-c", "printf 'a\\377b'"]);
	return { kind: NodeKind.NumberLiteral, line: 1, column: 1, value: r.output.length, isFloat: false };
}

macro errorLength(): Node {
	const r = execFileResult("/bin/sh", ["-c", "printf 'c\\377d' >&2"]);
	return { kind: NodeKind.NumberLiteral, line: 1, column: 1, value: r.errorOutput.length, isFloat: false };
}

console.log(`${outputLength()} ${errorLength()}`);
