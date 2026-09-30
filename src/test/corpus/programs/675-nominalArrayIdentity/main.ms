// @stdout: 5 2 | 2 5
// @exit: 0

import { forwardLayout } from "./forward";
import { reverseLayout } from "./reverse";

const forward = forwardLayout();
const reverse = reverseLayout();
if (forward != "5 2" || reverse != "2 5") throw new Error("nominal array layouts changed");
console.log(forward + " | " + reverse);
