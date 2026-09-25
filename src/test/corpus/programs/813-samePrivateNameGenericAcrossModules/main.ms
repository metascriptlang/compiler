// @stdout: 7 xy true | 3 3 z | k9
// @xfail(raiser): output differs from c: the non-generic Box of b.ms reads as [object]
import { fromA } from "./a";
import { fromB } from "./b";
import { fromC } from "./c";

console.log(`${fromA()} | ${fromB()} | ${fromC()}`);
