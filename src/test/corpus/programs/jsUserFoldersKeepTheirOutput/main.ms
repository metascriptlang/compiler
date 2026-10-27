// @stdout: _std/core/system/index.ms _prj/a.ms a.ms 3
// note: a project folder spelled like the compiler's own `_std` tree, or like the `_prj` folder that holds such paths, keeps its own output file on JS; the user `_std/core/system/index.ms` used to overwrite the std system module that range-checks `x as int64`, and `_prj/a.ms` must not meet it or `a.ms` after the move.
import { name as underscored } from "./_std/core/system/index.ms";
import { name as moved } from "./_prj/a.ms";
import { name as plain } from "./a.ms";
function truncated(x: float64): int64 { return x as int64; }
console.log(`${underscored} ${moved} ${plain} ${truncated(3.7)}`);
