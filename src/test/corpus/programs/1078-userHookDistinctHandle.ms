// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a user destroy hook on a handle-only distinct int32 makes the type need management.
type Id = distinct int32;
let destroyed = 0;
function onDestroy(this h: Id): void { destroyed += 1; }
function mk(): Id { return 5 as Id; }
function make(): void { const h: Id = mk(); console.log("made"); }
make();
console.log("destroyed " + destroyed.toString());
