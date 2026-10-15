// @stdout: a init
// @stdout: c init
// @stdout: shape init
// @stdout: k1 init
// @stdout: k2 init
// @stdout: r init
// @stdout: main 1 3 4 30 5
// note: every imported module's top-level code runs once, in import order, even when the only name taken from it is a `const` the checker folds into the importer. Before the fix C dropped such a module when another import came first: `c init`, `shape init`, `k1 init`, `k2 init` and `r init` were missing on C while JS printed them, and the JS module tree ran `shape` before `c`.
import { av } from "./lib/a";
import { cv } from "./lib/c";
import { origin } from "./lib/shape";
import { k1 } from "./lib/k1";
import { k2 } from "./lib/k2";
import { rv } from "./lib/hub";
console.log(`main ${av} ${cv} ${origin.x} ${k1 + k2} ${rv}`);
