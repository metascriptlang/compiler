// @stdout: value 5 left div0
// @stdout: value 5 right div0
// @stdout: n3 0
// note: two modules each declare a generic `type Either` and narrow an instance of it by its discriminant, so the lifecycle hooks of an instance body are named by its instance and never by the shared declaration name.

import { leftDiv, leftText } from "./left";
import { rightDiv, rightPair, rightText } from "./right";

console.log(leftText(leftDiv(10, 2)), leftText(leftDiv(1, 0)));
console.log(rightText(rightDiv(10, 2)), rightText(rightDiv(1, 0)));
const a = rightPair(3);
const b = rightPair(0);
console.log(a.ok ? a.value : "x", b.ok ? "x" : b.error);
