// @stdout: positions 9 12 15 unused 3 5 6 4
// @exit: 0

import { position, unchanged } from "./macros";

struct Thing { size: int32; }
struct Other { code: uint64; }

const a = position<Thing>();


const b = position<Thing>();


const c = position<Other>();
const zero = unchanged<int32[0]>(3);
const array = unchanged<int32[]>(5);
const named = unchanged<Thing>(6);
const plain = unchanged(4);
console.log(`positions ${a} ${b} ${c} unused ${zero} ${array} ${named} ${plain}`);
