// Parity program — a non-exported `hash` and `==` in an imported module reach the std Set and Map
// that module instantiates, so the instance placed beside the generic still calls the private ops
// on every backend: equal rows collapse to one key.
//
// @stdout: cells=3,3,r2
// @exit: 0

import { countCells } from "./lib/index";

console.log(`cells=${countCells([1, 2, 2, 3, 1])}`);
