// @stdout: 5
// @foreign-stdout: dispose releases: true
// @foreign-stdout: trap reaches the caller: ExitStatus: Program terminated with exit(1)
// @foreign-stdout: release after trap: ok true
import { Handle } from "std/ffi";
import { open, bump } from "./handleTrapWasm";
export { open, bump, bumpWild } from "./handleTrapWasm";

const a = open(4);
console.log(`${bump(a, 1)}`);
a.release();
