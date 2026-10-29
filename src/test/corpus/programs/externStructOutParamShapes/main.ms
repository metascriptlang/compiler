// Parity program — a struct the header defines is declared `extern struct`, so the value is the
// header's C type wherever a C function takes or returns it. A plain `struct` with the same fields
// is a distinct MetaScript struct, and C rejects its address where the header's type is expected.
// Axes: a struct returned by value, a struct holding two of it filled through an `out` parameter,
// and the nested value passed on as a pointer.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @xfail(raiser): raiser runtime error: Unknown host function: corpus1181Make
// @stdout: 3,4|1,2,30,40,0.5|9,12
// @exit: 0

@include("./ffi.h");

extern struct Point from "Corpus1181Point" { x: int32; y: int32; }
extern struct Seg from "Corpus1181Seg" { from: Point; to: Point; weight: float64; }

extern function corpus1181Make(x: int32, y: int32): Point;
extern function corpus1181Span(out s: Seg): void;
extern function corpus1181Scale(ref p: Point, k: int32): void;

const p = corpus1181Make(3, 4);
let s: Seg = { from: { x: 0, y: 0 }, to: { x: 0, y: 0 }, weight: 0 };
corpus1181Span(s);
let q = s.from;
q.x = 3;
q.y = 4;
corpus1181Scale(q, 3);
console.log(`${p.x},${p.y}|${s.from.x},${s.from.y},${s.to.x},${s.to.y},${s.weight}|${q.x},${q.y}`);
