// @stdout: 7
// @stdout: 42
import { seven, twice } from "./wasmModuleTopLevelWasm";

console.log(`${seven}`);
console.log(`${twice(21)}`);
