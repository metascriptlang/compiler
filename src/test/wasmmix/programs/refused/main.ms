// @mixed-error: Counter
// @mixed-error: 'make' in ~> the result has type ~> and a class instance has an identity on one heap and does not cross as a copy: return the values it holds as a struct
// @mixed-error: 'read' in ~> parameter 'c' has type ~> and a class instance has an identity on one heap and does not cross as a copy: pass the values it holds as parameters
// @mixed-error: 'make' in ~> sharing the instance itself waits for Handle<T>, which is planned
// @stdout: 7
// @stdout: 9
import { Counter, make, read } from "./refusedWasm";

const c = new Counter(7);
console.log(`${read(c)}`);
console.log(`${read(make(9))}`);
