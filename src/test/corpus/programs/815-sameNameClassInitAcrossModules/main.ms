// @stdout: 15 40
// @xfail(raiser): raiser runtime error: cannot evaluate 'super' at comptime: symbol kind is Class
import { sa } from "./a";
import { sb } from "./b";

console.log(`${sa()} ${sb()}`);
