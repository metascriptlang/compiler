// @xfail(raiser): raiser runtime error: Unknown host function: corpus890FillI32
// Parity program — a local passed to an imported `T*` or `void*` parameter reaches C as its own
// address, so the C writes land in the local (NIM-REF CK-102, Nim's `addr`).
// Axes: int32, uint16, double, bool and enum pointees; `void*` given a uint16, an enum and a
// struct; a struct field, an array element, a class field and a global; a `ref` parameter
// forwarded to `T*` and to `const T*`; `null` still passing.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 5,1,2.5,true,true|80,true,9|5,5,5,5|5,6|-1
// @exit: 0

@passC("-Werror=incompatible-pointer-types");

import {
	corpus890FillI32, corpus890NextRow, corpus890FillF64, corpus890FillBool, corpus890FillMode, corpus890ReadI32,
	corpus890Get, Corpus890Mode, Corpus890Cfg, Corpus890Key,
} from "./out.h";

interface Pair { x: int32; y: int32; }
class Box { n: int32 = 0; }

let total: int32 = 0;

function forward(ref n: int32): int32 {
	corpus890FillI32(n);
	return corpus890ReadI32(n) + 1;
}

let i: int32 = 0;
let y: uint16 = 0;
let f: number = 0;
let b = false;
let m = Corpus890Mode.CORPUS890_IDLE;
corpus890FillI32(i);
corpus890NextRow(y);
corpus890FillF64(f);
corpus890FillBool(b);
corpus890FillMode(m);

let cols: uint16 = 0;
let mode = Corpus890Mode.CORPUS890_IDLE;
let cfg: Corpus890Cfg = { base: 0, step: 0 };
corpus890Get(Corpus890Key.CORPUS890_KEY_COLS, cols);
corpus890Get(Corpus890Key.CORPUS890_KEY_MODE, mode);
corpus890Get(Corpus890Key.CORPUS890_KEY_CFG, cfg);

let pair: Pair = { x: 0, y: 0 };
const cells: int32[] = [0, 0];
const box = new Box();
corpus890FillI32(pair.y);
corpus890FillI32(cells[1]);
corpus890FillI32(box.n);
corpus890FillI32(total);

let r: int32 = 0;
const back = forward(r);

console.log(`${i},${y},${f},${b},${m == Corpus890Mode.CORPUS890_BUSY}|${cols},${mode == Corpus890Mode.CORPUS890_BUSY},${cfg.step}|${pair.y},${cells[1]},${box.n},${total}|${r},${back}|${corpus890FillI32(null)}`);
