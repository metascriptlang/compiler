// @stdout: modes Slow Auto
// @exit: 0
// note: two modules each export an enum `Mode`, and one module turns both into text. The toString routine of each is built from its own declared type and requested by its symbol; the second used to be dropped as a duplicate name, so C and JS called a function that was never emitted.

import { Mode as AMode, slowA } from "./a";
import { Mode as BMode, autoB } from "./b";

const a: AMode = slowA();
const b: BMode = autoB();
console.log("modes " + a.toString() + " " + String(b));
