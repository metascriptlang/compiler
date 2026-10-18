// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a user destroy hook on a distinct over a struct runs once when a value built by a function is dropped; a value cast from a local struct is a borrow of it and is not destroyed.
struct P { n: int32 }
type Handle = distinct P;
let destroyed = 0;
function onDestroy(this h: Handle): void { destroyed += 1; }
function mk(): Handle { const p: P = { n: 1 }; return p as Handle; }
function make(): void { const h: Handle = mk(); console.log("made"); }
make();
console.log("destroyed " + destroyed.toString());
