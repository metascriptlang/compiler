// @stdout: 7
// @xfail(raiser): raiser runtime error: Unknown host function — a C header import has no host bridge on the Raiser
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// note: one C file named through a symlinked directory, a dot segment and its header's own directory is compiled and linked once, so its function is not defined twice.
@compile("./alias/value.c");
@compile("./native/../native/value.c");
import { alloiumAliasValue } from "./native/value.h";
console.log(alloiumAliasValue());
