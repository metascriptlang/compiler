// A class static field is module state: one cell per program, shared by every thread. A spawn thunk
// that writes it, or reads it while it is mutable, runs on another thread against the main thread's
// cell, directly, through a const alias of the class, or through a routine the thunk calls.
// The legal neighbour is spawnStaticFieldAccepts.ms.
//
// GUARD-CHECK-FAIL it uses static 'C.n'
// GUARD-CHECK-FAIL it uses static 'D.items'
class C { static n: int32 = 17; }
class D { static items: int32[] = [1, 2]; }

const written = spawn((): int32 => { C.n += 1; return C.n; }); // GUARD-REFUSED
const read = spawn((): int32 => C.n); // GUARD-REFUSED
const K = C;
const viaAlias = spawn((): int32 => K.n); // GUARD-REFUSED
function bump(): int32 { C.n += 1; return C.n; }
const viaCall = spawn((): int32 => bump()); // GUARD-REFUSED
const viaRef = spawn((): int64 => D.items.length); // GUARD-REFUSED
console.log(await written + await read + await viaAlias + await viaCall + await viaRef);
