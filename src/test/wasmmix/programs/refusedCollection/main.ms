// @mixed-error: 'count' in ~> parameter 'm' has type ~> and a Map or Set is a hash table that lives on one heap and does not cross: pass its keys and values as separate Vec parameters of numbers and rebuild it on the other side (string keys have no Vec form yet)
// @mixed-error: 'uniq' in ~> the result has type ~> and a Map or Set is a hash table that lives on one heap and does not cross: return a Vec of numbers and rebuild it on the other side, a Map's keys from one @wasm function and its values from another
// @stdout: 2
// @stdout: 3
import { count, uniq } from "./refusedCollectionWasm";

const m = new Map<string, int32>();
m.set("a", 1);
m.set("b", 2);
console.log(`${count(m)}`);
const v: Vec<int32> = [1, 2, 2, 3];
console.log(`${uniq(v).size}`);
