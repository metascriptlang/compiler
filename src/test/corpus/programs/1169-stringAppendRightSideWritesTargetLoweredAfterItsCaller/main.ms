// @stdout: old0!
// note: main imports a before b, so b's string += is lowered before a's operator overload; the right side writes the target, so the target is read first.

import { again } from "./a";
import { run } from "./b";
run();
