// @stdout: 8 4
// @stdout: 8 12 4
import * as direct from "./lib";
import { lib } from "./mid";
console.log(`${direct.scale(4)} ${direct.greet("abc")}`);
console.log(`${lib.scale(4)} ${lib.scale(4, 3)} ${lib.greet("abc")}`);
