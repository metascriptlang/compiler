// note: two modules calling one @inline generic with the same type argument share its one
// instance, and the second caller copies the body that instance was lowered to. Same output on
// every lane.
import { first } from "./first";
import { second } from "./second";

const a = first();
const b = second();
console.log(a.ok ? a.value : -1, b.ok ? b.value : -1);
