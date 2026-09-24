// @stdout: imports 43 a-fast b-off A1 B4
// @exit: 0
// @xfail(drc): C names a class's init and an enum's type by the bare declared name, so two `Box` or two `Mode` from different modules collide (duplicate `Box_init` at link, the second `Mode`'s members undeclared)
// @xfail(orc): same C naming collision as drc
// @xfail(danger): same C naming collision as drc
// @xfail(raiser): the Raiser function table finds a constructor by the bare class name, so `new BoxB(2)` has no matching constructor
// note: two modules export a const `LIMIT`, an enum `Mode` and a class `Box` under the same names, and one module imports each pair through aliases. Each import is its own binding in the importing module: as separate JS files the two classes used to be imported under one name, a duplicate binding the module loader rejects.

import { LIMIT as limitA, Mode as ModeA, describe as describeA, Box as BoxA } from "./a";
import { LIMIT as limitB, Mode as ModeB, describe as describeB, Box as BoxB } from "./b";

console.log(`imports ${limitA + limitB} ${describeA(ModeA.Fast)} ${describeB(ModeB.Off)} ${new BoxA(1).show()} ${new BoxB(2).show()}`);
