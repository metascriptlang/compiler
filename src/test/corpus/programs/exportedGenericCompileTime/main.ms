// @stdout: 4|2|1
// @exit: 0
import { sizeCode } from "./sizes";
console.log([sizeCode<int32>(), sizeCode<uint16>(), sizeCode<boolean>()].join("|"));
