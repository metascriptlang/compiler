// @stdout: 3 2.5 | 4 6.5
// @exit: 0

import { makeId as leftId, makeSlot as leftSlot, show as leftShow } from "./left";
import { makeId as rightId, makeSlot as rightSlot, show as rightShow } from "./right";

const lefts = [leftId(), leftId()];
const rights = [rightId()];
const arrays = leftShow(lefts[1]) + " " + rightShow(rights[0]);
const slots = leftShow(leftSlot().item) + " " + rightShow(rightSlot().item);
console.log(arrays + " | " + slots);
