// @stdout: b init: threw before a declared fromA
// @stdout: a sees: a1
// @stdout: main: a1
// note: a namespace import names the binding by member read, not by an imported name; the cycle's first module still throws the ReferenceError JS throws instead of reading an empty string.
import * as A from "./a";
console.log(`main: ${A.fromA}`);
