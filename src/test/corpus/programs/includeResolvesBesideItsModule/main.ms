// @xfail(raiser): raiser runtime error: Unknown host function: fromA
// Parity program — a module's `@include` names the header beside that module, even when a module
// imported earlier puts a directory holding a header of the same name on the include path.
// Axes: a bare name and a `./` name, one directory and two directories below the program.
//
// @skip-js: a C header binds C symbols; the JS backend has no C linkage
// @stdout: 1 2 3
import { callA } from "./a/a";
import { callB } from "./b/b";
import { callC } from "./c/sub/c";

console.log(`${callA()} ${callB()} ${callC()}`);
