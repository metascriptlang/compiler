// Parity program — std/process argv is [program, ...args] and its sibling externs reach the
// importing module on every backend; the corpus runs a program with no arguments, so the list
// is exactly the program itself. The JS-on-node list used to be [node, script] (length 2), and
// the per-module tree never bound argv/cwd/exit in the importing module.
// Axes: argv length, argv[0] present, slice past the program, cwd, exit code.
//
// @exit: 3

import { argv, cwd, exit } from "std/process";

console.log(`argc ${argv.length}`);
console.log(`program ${argv[0].length > 0 ? "set" : "empty"}`);
console.log(`rest ${argv.slice(1).length}`);
console.log(`cwd ${cwd().length > 0 ? "set" : "empty"}`);
exit(3);
