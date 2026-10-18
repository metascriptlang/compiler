// @stdout: n4 sy p5 t2 a3 o1
// note: a call through a namespace import picks among every overload the module declares under that name, generic ones included, as a call through a named import does.
import * as L from "./lib";

const xs: int32[] = [1, 2, 3];
console.log(L.tag(4), L.tag("y"), L.tag(2, 3), L.size("ab"), L.size(xs), L.solo(1));
