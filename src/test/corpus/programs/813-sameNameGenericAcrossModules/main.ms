// @stdout: same-name a:1 b:2 a:s b:t | a012 21b0
// @exit: 0
// note: two modules each declare a generic `wrap<T>` and a recursive generic `countdown<T>`, and one module calls both through aliases with the same type arguments. An instance belongs to the generic it was made from, so `wrapB(2)` runs b's body even though both instances spell `wrap__number`; the recursive call inside each body finds its own generic's instance. The module that holds both used to reuse whichever instance it made first and print `a:2`.

import { wrap as wrapA, countdown as countdownA } from "./a";
import { wrap as wrapB, countdown as countdownB } from "./b";

console.log(`same-name ${wrapA(1)} ${wrapB(2)} ${wrapA("s")} ${wrapB("t")} | ${countdownA(0, 2)} ${countdownB(0, 2)}`);
