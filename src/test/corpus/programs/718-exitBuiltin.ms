// @stdout: exit-builtin before
// @exit: 3
import { exit } from "std/process";

console.log("exit-builtin before");
exit(3);
console.log("exit-builtin after");
