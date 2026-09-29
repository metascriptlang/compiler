// @stdout: a6
// note: a.ms and main.ms each instantiate twice<int32>; placement keeps one copy of the instance, the one a.ms asked for, and only a dead function of a.ms calls it. main's call goes through its own instance symbol, so a reachability keyed by symbol has to reach the kept copy (same generic, same instance name) or the call links to nothing.

import { twice } from "./lib";
import { label } from "./a";
const pair = twice<int32>(3);
console.log(label() + String(pair[0] + pair[1]));
