// @xfail(raiser): raiser runtime error: Unknown host function: corpusRowMake
// Parity program — a fixed C array, a struct field or a global, imports as a sized array of its
// element and is read and written as the C array it is.
// Axes: a scalar element, a struct element, a byte element, a global; read, write, a write C
// sees through a pointer, a whole-array copy, and a read through a pointer to the struct.
//
// @skip-js: a C header import binds C symbols; the JS backend has no C linkage
// @stdout: 1 4 8 98 5 12|101 20 3 70 125 4
// @exit: 0

import { corpusRowMake, corpusRowBump, corpusRowSum, corpusTable, CorpusRow } from "./fixed.h";

let row: CorpusRow = corpusRowMake();
const first = `${row.v[0]} ${row.v[3]} ${row.cells[1].x} ${row.tag[1]} ${corpusTable[0]} ${corpusTable[7]}`;
row.v[1] = 20;
row.cells[0].x = 70;
corpusRowBump(row as Ptr<CorpusRow>);
const copy = row.v;
row.v[2] = 0;
const viaPtr = row as Ptr<CorpusRow>;
console.log(`${first}|${row.v[0]} ${row.v[1]} ${copy[2]} ${row.cells[0].x} ${corpusRowSum(row)} ${viaPtr.v[3]}`);
