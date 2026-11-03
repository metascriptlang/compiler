// @mixed-error: is lent for the call
// @columns: mixed
// @stdout: 1
import { open, keep } from "./refusedLentUseWasm";

console.log(`${keep(open(1))}`);
