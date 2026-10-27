// @stdout: 7
// @stdout: 8
// note: main imports a only, so b is lowered before the async later it hands callbacks to; each callback reads a cell freed when run returns, then reused by a Pad.

import { again } from "./a";
again();
