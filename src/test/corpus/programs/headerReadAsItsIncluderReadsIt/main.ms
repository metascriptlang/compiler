// @xfail(raiser): raiser runtime error: Unknown host function: twice
// Parity program — a header is read as the header that includes it reads it, as one C
// translation unit reads every header it includes.
// Axes: a typedef of a typedef, declared and used in an included header, leaves the declarations
// of the header it aliases spelled as they read alone (`quoted.h`, quoted includes); a header
// reached through an angle include is read with the search paths of the header that included
// it (`top.h` includes `<lib/sub/tally.h>`, which includes `<lib/types.h>`).
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 8 3|20
// @exit: 0

@passC("-I./include");
import { Tally, Id, twice } from "./include/lib/top.h";
import { scaled } from "./scaled";

const t: Tally = { id: 3, n: 4 };
const id: Id = t.id;
console.log(`${twice(t.n)} ${id}|${scaled()}`);
