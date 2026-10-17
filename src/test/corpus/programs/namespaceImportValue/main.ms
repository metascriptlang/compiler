// Parity program — a namespace import read as a value (`const d = lib`, an argument, a field,
// a call result) reaches the module's own exports, live, on every lane.
//
// @stdout: value hi 42 | arg hi | field hi 42
// @stdout: call 1 hi | array 42
// @stdout: live 43 43 | truthy object

import * as lib from "./lib";

interface Holder { m: typeof lib; }

function viaArg(n: typeof lib): string { return n.hi(); }

let calls: int32 = 0;
function getNs(): typeof lib { calls += 1; return lib; }

const d = lib;
const h: Holder = { m: lib };
const arr = [lib, d];
console.log(`value ${d.hi()} ${d.answer} | arg ${viaArg(d)} | field ${h.m.hi()} ${h.m.answer}`);
const called = getNs().hi();
console.log(`call ${calls} ${called} | array ${arr[1].answer}`);
lib.bump();
console.log(`live ${d.answer} ${h.m.answer} | ${d ? "truthy" : "falsy"} ${typeof d}`);
