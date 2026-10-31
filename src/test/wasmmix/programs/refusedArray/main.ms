// @mixed-error: 'sum' in ~> parameter 'xs' has type ~> and an array reference lives on one heap and does not cross: use a Vec of bool, integer or float elements, which crosses as a copy
// @mixed-error: 'halves' in ~> the result has type ~> and an array reference lives on one heap and does not cross: return a Vec of bool, integer or float elements, which crosses as a copy
// @stdout: 6
// @stdout: 3
import { halves, sum } from "./refusedArrayWasm";

const xs: int32[] = [1, 2, 3];
console.log(`${sum(xs)}`);
console.log(`${halves(3).length}`);
