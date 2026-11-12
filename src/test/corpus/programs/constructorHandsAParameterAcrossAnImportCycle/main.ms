// @stdout: tkk
// note: two modules that import each other, each with a constructor that hands its parameter to a constructor of the other. The caller and both bodies agree on who takes the parameter: the one kept only through an Unowned edge lives to the end of the caller's scope, and the one the other module's constructor stores in an owning field is still there to read through it.
import { both } from "./a";

console.log(both());
