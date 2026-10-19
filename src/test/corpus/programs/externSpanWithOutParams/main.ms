// @xfail(raiser): raiser error: Cannot resolve module './lib' (an extern C module)
// Parity program — an `extern function` whose Span parameter becomes two C arguments (data, len)
// still passes each `out` argument by address, wherever the `out` stands.
// Axes: Span then out; out, Span, out; Span, out, scalar; two Spans with an out between and after;
// the same extern exported from another module.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @stdout: 7 4 4 43 11 12 7
// @exit: 0
import { spanThenOutElsewhere } from "./lib";

@include("./ffi.h");

extern function spanThenOut(xs: Readonly<Span<uint8>>, out w: uint64): void from "corpusSpanThenOut";
extern function outSpanOut(out a: uint64, xs: Readonly<Span<uint8>>, out b: uint64): void from "corpusOutSpanOut";
extern function spanOutScalar(xs: Readonly<Span<uint8>>, out w: uint64, k: int64): void from "corpusSpanOutScalar";
extern function twoSpans(xs: Readonly<Span<uint8>>, out m: uint64, ys: Readonly<Span<uint8>>, out t: uint64): void from "corpusTwoSpans";

const buf: Vec<uint8> = [3, 4, 5, 6];
const pair: Vec<uint8> = [7, 9];
let w: uint64 = 0;
spanThenOut(buf, w);
let a: uint64 = 0;
let b: uint64 = 0;
outSpanOut(a, buf, b);
let s: uint64 = 0;
spanOutScalar(buf, s, 10);
let m: uint64 = 0;
let t: uint64 = 0;
twoSpans(buf, m, pair, t);
let e: uint64 = 0;
spanThenOutElsewhere(buf, e);
console.log(`${w} ${a} ${b} ${s} ${m} ${t} ${e}`);
