// @stdout: a 3 true b 7
// note: a generic function reached through `import * as ns` names its instance, not the template (split JS printed "ns.id is not a function"); a generic class's raw template emits no JS of its own, so its body never references an uninstantiated routine.
import * as ns from "./lib";

const s = new ns.Shelf<string>();
s.put("a");
s.put("b");
const n = new ns.Shelf<int32>();
n.put(7 as int32);
console.log(`${ns.id("a")} ${ns.id(3)} ${ns.id(true)} ${s.top()} ${n.top()}`);
