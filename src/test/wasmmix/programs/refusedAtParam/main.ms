// @mixed-error: refusedAtParamWasm.ms:9:25
// @stdout: 7
import { Counter, read } from "./refusedAtParamWasm";

const c = new Counter(7);
console.log(`${read(c)}`);
