// @stdout: base 1 10
// @stdout: local first 5 10
// @stdout: star first 5 10
// @stdout: named first 5 10
// @stdout: named last 5 10
// @stdout: hidden init
// @stdout: shadowed only 5
// @stdout: cycle 1 2 1 2
// @exit: 0

import { dup as base, only } from "./base";
import { dup as localFirst, only as localOnly } from "./localFirst";
import { dup as starFirst, only as starOnly } from "./starFirst";
import { dup as namedFirst, only as namedFirstOnly } from "./namedFirst";
import { dup as namedLast, only as namedLastOnly } from "./namedLast";
import { dup as shadowedOnly } from "./shadowedHub";
import { pv as fromP, qv as throughP } from "./cycleP";
import { pv as throughQ, qv as fromQ } from "./cycleQ";

console.log("base", base, only);
console.log("local first", localFirst, localOnly);
console.log("star first", starFirst, starOnly);
console.log("named first", namedFirst, namedFirstOnly);
console.log("named last", namedLast, namedLastOnly);
console.log("shadowed only", shadowedOnly);
console.log("cycle", fromP, throughP, throughQ, fromQ);
