// @stdout: 16 100 100
// @exit: 0
// note: type text in a quote names the macro module's declarations wherever it sits: the sizeof operand, a class property, a method signature and a predicate target. The caller declares namesakes of a different shape, so a type rebound at the expansion prints another size (8, a reference) or fails to compile.

import { sizes } from "./lib";

class Box { w: string = "caller"; }
class Pair { w: string = "caller"; }

console.log(sizes(0));
