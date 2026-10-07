import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { Counter } from "./logic";

console.log(`HCR-GLOBAL start: ${Counter()}`);
const result = change("g2", ["logic"]);
console.log(`HCR-GLOBAL g2: ${reloadKindName(result.kind)} ${result.modules.join(",")}`);
console.log(`HCR-GLOBAL after: ${Counter()}`);
