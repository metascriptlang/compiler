// @exit: 1
// @stdout: Error: unhandled exception: b failed
// @skip-js: node reports the uncaught error with its own stack trace on stderr, and parity compares merged stdout+stderr (sibling of 1021)
// @skip-raiser: the raiser writes its uncaught-error report to a stderr its lane does not read, so its output cannot match C's merged stdout+stderr (sibling of 1021)
// note: a throw in an imported module's top level stops the program before any importer's top level runs: a's and main's top levels would each replace the error with their own.
import { doubled } from "./lib/a";
if (doubled == 0) throw new Error("main ran on a zero value");
console.log(`doubled=${doubled}`);
