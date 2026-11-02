// @mixed-error: crosses as Handle<Counter>
// @stdout: 7
import { open } from "./refusedClassWasm";

console.log(`${open(7).n}`);
