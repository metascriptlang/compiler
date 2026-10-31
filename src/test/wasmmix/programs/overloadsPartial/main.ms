// @mixed-error: @wasm is on 1 of its 2 overloads
// @stdout: 8
// @stdout: hi!
import { pick } from "./overloadsPartialWasm";

const n: int32 = 7;
console.log(`${pick(n)}`);
console.log(`${pick("hi")}`);
