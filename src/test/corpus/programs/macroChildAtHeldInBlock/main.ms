// @stdout: b|1:43
// @exit: 0
// note: `childAt` hands the caller a held child, so a local that goes out of its block releases its own count and the macro's later reads stay valid; the block-scoped local used to release a child the node still owned and the macro returned `<object>`.

import { viaIf, viaLoop } from "./walk";

function f(a: int32): int32 { return a + 1; }

console.log([viaIf(f), viaLoop(f)].join("|"));
