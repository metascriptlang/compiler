// @stdout: 7
// note: main imports a before b, so b is lowered before a; b's call into a reads a's body before a is lowered.

import { again } from "./a";
import { run } from "./b";
run();
