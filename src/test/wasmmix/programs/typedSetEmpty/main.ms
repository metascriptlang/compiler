// @stdout: 1 2 3 4 5
import { scaleI } from "./typedSetEmptyWasm";

let nx: int32[5] = [1, 2, 3, 4, 5];
const k: int32 = 7;
scaleI(nx[k..k], 3);
console.log(`${nx[0]} ${nx[1]} ${nx[2]} ${nx[3]} ${nx[4]}`);
