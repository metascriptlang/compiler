// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a user destroy hook on a distinct string runs once when the value is dropped.
type Name = distinct string;
let destroyed = 0;
function onDestroy(this h: Name): void { destroyed += 1; }
function mk(): Name { return ("a" + "b") as Name; }
function make(): void { const h: Name = mk(); console.log("made"); }
make();
console.log("destroyed " + destroyed.toString());
