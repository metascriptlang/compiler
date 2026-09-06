// @stdout: cross-name ok

// Two std modules export the same function name — string.byteAt on string,
// buffer.byteAt on Buffer — one cross-module overload set, legal on both
// backends. The per-file JS emitter must derive that name from the export
// surface identically on the declaring and the referencing side: the
// declaring side compiles the module alone and cannot see the set through
// symbol state, and a name that only one side suffixes becomes an export
// of something never defined (SyntaxError at import time). The C lane
// mangles by module and was never at risk; this pin is for the js lane.

import { byteAt } from "std/core/string";
import { Buffer } from "std/core/buffer";

function main(): void {
	const b = Buffer.alloc(2);
	if (b.byteLength() != 2) { console.log("FAIL buffer unit"); return; }
	if (byteAt("AB", 0) != 65) { console.log("FAIL string byteAt"); return; }
	console.log("cross-name ok");
}

main();
