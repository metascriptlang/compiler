// @stdout: 7
// @exit: 0
// note: the `error(...)` intrinsic returns `never`, so the guard `if (!found.ok) { error(...); }` in a macro body narrows the reads after it, one loop deep and two loops deep alike.

import { total } from "./total";

console.log(total(1));
