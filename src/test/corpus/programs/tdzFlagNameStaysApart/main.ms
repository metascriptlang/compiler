// @stdout: b init: caught caught
// @stdout: a sees: a1 7
// @stdout: main: a1:user:7:9
// note: a user binding spelled `<name>$init` beside a binding that needs the compiler's init flag is a different variable from that flag; the C definitions used to collide.
import { show } from "./a";
console.log(`main: ${show()}`);
