// @mixed-error: the module variable 'total' is used by wasm-placed function 'bump'
// @columns: mixed
// @stdout: 3
import { bump, peek } from "./refusedSharedStateViaWasm";

bump(3);
console.log(`${peek()}`);
