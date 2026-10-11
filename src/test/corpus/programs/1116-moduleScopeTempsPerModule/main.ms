// @stdout: 1,2,1,2,2,one,-1 10,11,10,20,2,ten,10 100,101,100,200,2,many,100
// note: three modules each destructure an array and an object, spread an array, match and coalesce at module scope. The temporaries the compiler declares for these sit at module scope too, so in a JS bundle each needs the per-module name its neighbours' bindings carry; on C they stay apart per file. Same output on every backend.

import { firstSummary } from "./lib/first";
import { secondSummary } from "./lib/second";
import { thirdSummary } from "./lib/third";

console.log(`${firstSummary()} ${secondSummary()} ${thirdSummary()}`);
