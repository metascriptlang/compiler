// A macro body that calls readFileBytes compiles on a C build: the Raiser prelude its helpers run from
// takes the Raiser branch of the `when (c)` blocks it reaches. macroBufferCodecInVm pins the codec alone.
//
// @skip-js: on the JS target a macro calling readFileBytes fails its Error identity check, a separate defect
// @stdout: missing=false
// @exit: 0

import { Node, NodeKind } from "std/meta";
import { readFileBytes } from "std/fs";

macro bytesAtCompileTime(at: Node): Node {
	const missing = readFileBytes("/tmp/mscorpusMacroReadsFileBytes.missing");
	return { kind: NodeKind.StringLiteral, line: at.line, column: at.column, value: "missing=" + (missing.ok ? "true" : "false") };
}

console.log(bytesAtCompileTime(0));
