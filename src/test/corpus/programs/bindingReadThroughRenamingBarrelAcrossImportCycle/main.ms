// @stdout: b init: threw before a declared fromA
// @stdout: a sees: a1
// @stdout: main: a1
// note: a barrel that renames the binding hides its declared name from every import entry; the flag follows the declaring symbol, so the read through the barrel still throws before the declaration.
import { renamedA } from "./c";
console.log(`main: ${renamedA}`);
