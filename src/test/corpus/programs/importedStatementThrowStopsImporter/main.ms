// @exit: 1
// @stdout: Error: unhandled exception: m failed
// @skip-js: node reports the uncaught error with its own stack trace on stderr, and parity compares merged stdout+stderr (sibling of 1021)
// @skip-raiser: the raiser writes its uncaught-error report to a stderr its lane does not read, so its output cannot match C's merged stdout+stderr (sibling of 1021)
// note: a bare throwing statement in an imported module stops the program before the importer's top level runs, which would replace the error with its own.
import { label } from "./lib/m";
if (label != "m ready") throw new Error("main ran before m was ready");
console.log(label);
