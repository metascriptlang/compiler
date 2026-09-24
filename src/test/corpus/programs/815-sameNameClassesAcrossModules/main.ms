// @stdout: classes A1 B4
// @exit: 0
// @xfail(drc): C names a class's init by the bare class name, so two `Box` from different modules both define `Box_init` and the link fails
// @xfail(orc): same C naming collision as drc
// @xfail(danger): same C naming collision as drc
// @xfail(raiser): the Raiser function table finds a constructor by the bare class name, so `new BoxB(2)` has no matching constructor
// note: two modules export a class `Box`, and one module imports both through aliases. As separate JS files the two used to be imported under one name, a duplicate binding the module loader rejects; each import is now its own binding.

import { Box as BoxA } from "./a";
import { Box as BoxB } from "./b";

console.log(`classes ${new BoxA(1).show()} ${new BoxB(2).show()}`);
