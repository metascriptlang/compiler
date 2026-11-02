// @mixed-error: Counter
// @mixed-error: 'make' in ~> the result has type ~> and a class instance has an identity on one heap and does not cross as a copy: return the values it holds as a struct
// @mixed-error: 'read' in ~> parameter 'c' has type ~> and a class instance has an identity on one heap and does not cross as a copy: pass the values it holds as parameters
// @mixed-error: 'make' in ~> Counter has no JS/wasm boundary form: it crosses as Handle<Counter>
// @stdout: 7
// @stdout: 9
import { Counter, make, read } from "./refusedWasm";

const c = new Counter(7);
console.log(`${read(c)}`);
console.log(`${read(make(9))}`);
