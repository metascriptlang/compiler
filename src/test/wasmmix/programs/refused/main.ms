// @mixed-error: Counter
// @stdout: 7
import { Counter, read } from "./refusedWasm";

const c = new Counter(7);
console.log(`${read(c)}`);
