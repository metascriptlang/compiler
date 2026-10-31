// @mixed-error: 'adder' in ~> the result has type ~> and a function crosses the boundary only as a parameter, borrowed for the call, so it cannot be a result: return the value it computes
// @mixed-error: 'apply' in ~> field 'run' of parameter 'o' has type ~> and a function crosses the boundary only as a parameter, borrowed for the call, so it cannot be a struct field: pass it as a separate parameter
// @stdout: 7
// @stdout: 16
import { Op, adder, apply } from "./refusedFunctionWasm";

console.log(`${adder(3)(4)}`);
const o: Op = { run: (x: int32): int32 => x * 3, base: 4 };
console.log(`${apply(o)}`);
