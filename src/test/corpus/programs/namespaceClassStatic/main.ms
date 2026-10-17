// @xfail(raiser): the Raiser cannot read a static class field (inbox card 2026-10-09-raiser-cannot-read-a-static-class-field.md)
// @stdout: lib before
// @stdout: static K
// @stdout: lib after
// @stdout: start
// @stdout: 1
//
// A static field read through a namespace import is the class's field: its initializer
// runs once, at its place in the module body.

import * as m from "./lib";

console.log("start");
console.log(`${m.K.v}`);
