// @stdout: src/core/x.ms Aa|...abab|abab--- leaf
// @stdout: src/core/x.ms Aa|...abab|abab--- leaf
// @exit: 0
// note: a macro helper checked by the build calls std string edits (`split`, `replace`, `replaceAll`, `padStart`, `padEnd`, and `split` through a second helper). The macro VM runs their Raiser tier; the C build's bodies write string bytes through pointers, and lowering them stopped the build with an internal error that bytes.rms had no Raiser tier of 'findBytesFrom'.

import { slashedAt, editedAt, leafAt, slashed, edited, lastSegment } from "./lib";

console.log(slashedAt(0) + " " + editedAt(0) + " " + leafAt(0));
console.log(slashed("src\\core\\x.ms") + " " + edited("abab") + " " + lastSegment("a\\b\\leaf"));
