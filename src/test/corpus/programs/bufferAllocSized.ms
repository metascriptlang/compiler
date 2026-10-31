// @stdout: alloc=3 zero=true unsafe=2 written=7

import { Buffer } from "std/core/buffer";

const zeroed = Buffer.alloc(3);
const scratch = Buffer.allocUnsafe(2);
scratch[1] = 7;
console.log(`alloc=${zeroed.length} zero=${zeroed[0] == 0 && zeroed[2] == 0} unsafe=${scratch.length} written=${scratch[1]}`);
