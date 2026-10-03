// @stdout: left 7 12 | lb5 rb9 1.5 | xy 17
// @exit: 0

import { makeCell as leftCell, makeBox as leftBox, makeAnon as leftAnon } from "./left";
import { makeCell as rightCell, makeBox as rightBox, makeAnon as rightAnon } from "./right";

const lc = leftCell();
const rc = rightCell();
const lb = leftBox();
const rb = rightBox();
const la = leftAnon();
const ra = rightAnon();
const cells = lc[0].text + " " + rc[0].count.toString() + " " + lc[1].toString() + rc[1].toString();
const boxes = lb[0].tag + lb[0].item.toString() + " " + rb[0].tag + rb[0].item.toString() + " " + rb[0].extra.toString();
const anons = la[0].a + la[0].b + " " + (ra[0].c + ra[0].d).toString();
console.log(cells + " | " + boxes + " | " + anons);
