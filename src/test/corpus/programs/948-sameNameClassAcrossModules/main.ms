// @xfail(raiser): the Raiser bytecode compiler cannot evaluate a class static field (symbol kind is Class), also on the baseline
// @stdout: 60 dkx200 12 a
// note: two modules declare classes of the same names; each constructor keeps its own signature and defaults, and each static field its own global (codegen-c-6: C declared b's Node_init with a's int32_t parameter, JS took a's default, and both statics linked to one Counter__total).

import { makeA, Counter } from "./sameNameClassA";
import { makeB } from "./sameNameClassB";

Counter.total = Counter.total + 10;
console.log(makeA(), makeB(), Counter.total, Counter.label);
