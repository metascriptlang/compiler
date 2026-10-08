// note: an @inline generic instantiated with the same type arguments from several modules is
// one instance: every caller module copies the body the placed instance was lowered to (`try`,
// `match`, `??`, `Result.err`), whichever module asked first. A second type argument from
// another module is its own instance. Imports run third, first, second, so the module that
// asked first is neither the first nor the last caller. Same output on every lane.
import { third } from "./third";
import { first } from "./first";
import { second } from "./second";
import { wide } from "./wide";
import { viaTry, tally } from "./lib";

console.log(first(1));
console.log(second(3));
console.log(third(-4));
console.log(first(150), second(0));
console.log(wide(0), wide(-1));
console.log(tally(viaTry<int32>(5, 50)));
