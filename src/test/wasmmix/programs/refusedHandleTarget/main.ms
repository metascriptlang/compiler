// @mixed-error: T must be an exported class or struct
// @columns: mixed
// @stdout: 1
import { open } from "./refusedHandleTargetWasm";

open(1);
console.log("1");
