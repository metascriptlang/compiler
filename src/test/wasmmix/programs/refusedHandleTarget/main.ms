// @mixed-error: Handle<P>: T must be an exported class, as in Handle<Counter>
// @columns: mixed
// @stdout: 1
import { open } from "./refusedHandleTargetWasm";

open(1);
console.log("1");
