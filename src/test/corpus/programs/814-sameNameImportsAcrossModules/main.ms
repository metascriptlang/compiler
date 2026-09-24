// @stdout: imports 43 a-fast b-off
// @exit: 0
// note: two modules export a const `LIMIT` and an enum `Mode` under the same names, and one module imports both pairs through aliases. C keyed an emitted enum type by its bare name, so the second `Mode` was taken for the first and its members were never declared; each import is its own binding in the importing module on every backend.

import { LIMIT as limitA, Mode as ModeA, describe as describeA } from "./a";
import { LIMIT as limitB, Mode as ModeB, describe as describeB } from "./b";

console.log(`imports ${limitA + limitB} ${describeA(ModeA.Fast)} ${describeB(ModeB.Off)}`);
