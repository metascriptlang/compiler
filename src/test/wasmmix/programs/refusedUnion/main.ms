// @mixed-error: 'weigh' in ~> parameter 'v' has type ~> and a union has no single boundary form: pass a tag integer and the payload as separate parameters, or give each variant its own @wasm function
// @mixed-error: 'pick' in ~> the result has type ~> and a union has no single boundary form: return a struct with a tag integer and one field per variant, or give each variant its own @wasm function
// @stdout: 4
// @stdout: 8
// @stdout: -1
import { pick, weigh } from "./refusedUnionWasm";

let i: int32 = 3;
console.log(`${weigh(i)}`);
console.log(`${weigh(pick(true))}`);
console.log(`${weigh(pick(false))}`);
