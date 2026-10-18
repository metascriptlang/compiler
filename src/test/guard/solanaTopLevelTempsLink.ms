// GUARD-OS solana
// A temporary the lowerings bind for top-level code (a ternary's value, a nested call's result) is a
// local of the module's init function, as the author never declared it at module scope.
// RED MEANS: the temporary went to file-scope storage: FREESTANDING E02 refused the ternary as a
// module-level 'let', or the SBF link failed on a nested call's result in the discarded .bss.
import { instructionData, logU64 } from "std/solana";

struct Span { lo: uint64; hi: uint64; }

function widen(n: uint64): Span { return { lo: n, hi: n + 8 }; }
function width(s: Span): uint64 { return s.hi - s.lo; }

logU64(instructionData().length > 2 ? width(widen(instructionData().length as uint64)) : 7);
logU64(width(widen(width(widen(3)))) + width({ lo: 1, hi: instructionData().length as uint64 }));
