// @stdout: cycle 112 21
// note: two modules that import each other's functions. The module checked first binds to the symbols the other module's first phase collected; that module's second phase takes the same symbols over, so both sides call one declaration each. Before, the early side held a placeholder copy whose type was patched from the export table at emission.
import { fa } from "./a";
import { fb } from "./b";

console.log(`cycle ${fa(3)} ${fb(3)}`);
