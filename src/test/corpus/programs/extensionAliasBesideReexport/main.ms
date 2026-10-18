// @stdout: t1 t1 t1
// note: a module that imports an extension under an alias and re-exports from the extension's module, named or `*`, leaves the extension callable under its own name in a module that imports both.
import { viaNamed } from "./named";
import { viaStar } from "./star";
import { R, text } from "./a";

const r: R = { id: 1 };
console.log(r.text() + " " + viaNamed(r) + " " + viaStar(r));
