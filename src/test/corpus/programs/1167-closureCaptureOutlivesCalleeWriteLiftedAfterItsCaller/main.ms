// @stdout: 7
// note: main imports a before b, so b is lambda-lifted before a is transformed; b keeps a capture uncounted only if a's pop cannot drop it.

import { again } from "./a";
import { run } from "./b";
run();
