// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: reexport 42 true 5 4 false 9
// note: a class re-exported through a named hub and through `export *`. The hub re-exports the declaring module's own symbols, so the class keeps one set of methods; multi-file JS used to export a method name (`K_get_u0`) the hub never defined, and node refused to load the module.
import { f, Color, K } from "./hub";
import { g, K as StarK, Color as StarColor } from "./star";

console.log(`reexport ${f(21)} ${Color.Blue == Color.Blue} ${new K(5).get()} ${f(g(1))} ${StarColor.Green == StarColor.Red} ${new StarK(9).get()}`);
