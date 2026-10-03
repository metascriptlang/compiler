// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: hook-runs 1
// @exit: 0
// note: two modules declare a class `Cell`, only a's has a user destroy hook; a hook binds to the class it is declared on, so b's Cell must not run it.

import { runA, destroyedCount } from "./a";
import { runB } from "./b";

runA();
runB();
console.log("hook-runs " + destroyedCount().toString());
