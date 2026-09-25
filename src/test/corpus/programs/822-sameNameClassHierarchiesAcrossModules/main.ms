// @stdout: woof... bark~~~
// @exit: 0
// @xfail(raiser): raiser runtime error: cannot evaluate 'super' at comptime: symbol kind is Class
// note: two modules each declare a class `Animal` with subclasses `Dog` (overrides `speak`) and `Pup` (inherits it), and each calls through the base type. A subclass's TypeInfo points at its own module's base TypeInfo; reachability used to follow the base by name to one module only, so the other module's base TypeInfo was dropped and C failed to link. The dispatch table keyed methods by class and method name, so the second `Animal.speak` counted as an overload and C called the base method for every subclass.

import { talkA } from "./a";
import { talkB } from "./b";

console.log(talkA() + " " + talkB());
