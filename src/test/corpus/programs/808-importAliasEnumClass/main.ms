// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: alias 2 4 6 true false 8 2
// note: one declaration imported under several names. The alias is a name in the importer's scope, not a property of the symbol: C and JS both name the callee, class, enum and variable after the declaration. `C.Green` used to find its enum by the type's name `Color`, which the importing module never declared, so JS read an unbound `Color_Green`.
import { f as g1, f as g2, Color as C, K as Box, bump as tick, counter as seen } from "./lib";
import { f } from "./lib";

const b = new Box(8);
tick();
tick();
console.log(`alias ${g1(1)} ${g2(2)} ${f(3)} ${C.Green == C.Green} ${C.Red == C.Blue} ${b.get()} ${seen}`);
