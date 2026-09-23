// @xfail(raiser): raiser runtime error: Unknown host function: corpus800SetU32
// Parity program — an `out` / `ref` parameter of an `extern function` reaches C as one pointer
// to the caller's location. The transform already takes the implicit address of every argument
// bound to a Var formal; a second address in codegen hands C a pointer to a temp holding the
// address, which clang rejects for a scalar and which a struct would receive as garbage.
// Axes: `out` on uint32, `ref` on int64 (read-modify-write), `out` on a struct.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @stdout: 42|1000000000005|7,-3,1099511627776
// @exit: 0

@include("./ffi.h");

struct Info { cb: uint32; mode: int16; size: uint64; }

extern function corpus800SetU32(out v: uint32): void;
extern function corpus800AddI64(ref v: int64): void;
extern function corpus800Fill(out i: Info): void;

let a: uint32 = 0;
corpus800SetU32(a);
let b: int64 = 5;
corpus800AddI64(b);
let c: Info = { cb: 0, mode: 0, size: 0 };
corpus800Fill(c);
console.log(`${a}|${b}|${c.cb},${c.mode},${c.size}`);
