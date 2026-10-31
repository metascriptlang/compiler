// @mixed-error: refusedAtResultWasm.ms:9:33
// @stdout: 5
import { make } from "./refusedAtResultWasm";

console.log(`${make(5).n}`);
