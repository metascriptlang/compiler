// @stdout: 2,4,6 b+c 3/4|2,4,6 b+c 3/4
// @exit: 0
// note: a macro helper checked by the build calls a std array generic (`map`, `slice`, and one through a second helper). The macro VM runs the Raiser variant of that generic for the same type arguments; it used to rerun the build's variant, whose body calls a private extern only the build's std declares.

import { mapped, sliced, nested, doubled, rest, bumpedTail } from "./lib";

const atCompile = mapped(0) + " " + sliced(0) + " " + nested(0);
const atRun = doubled([1, 2, 3]) + " " + rest(["a", "b", "c"]) + " " + bumpedTail([1, 2, 3]);
console.log(atCompile + "|" + atRun);
