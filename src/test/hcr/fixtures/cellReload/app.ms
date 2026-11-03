import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { own, count, release } from "./holder";
import { step } from "./logic";

own();
console.log(`HCR-CELL g1: ${step()} ${count()}`);
const second = change("g2", ["logic"]);
own();
console.log(`HCR-CELL g2: ${reloadKindName(second.kind)} ${second.modules.join(",")} ${step()} ${count()}`);
const third = change("g3", ["logic"]);
console.log(`HCR-CELL g3: ${reloadKindName(third.kind)} ${third.modules.join(",")} ${step()} ${count()}`);
release();
console.log(`HCR-CELL released ${count()}`);
