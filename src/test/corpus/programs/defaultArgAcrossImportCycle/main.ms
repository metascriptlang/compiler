// @stdout: h1 v4 t4 items
// note: a default argument written in a module of an import cycle is read in that module, also when the
// caller is checked first: an enum member, a private helper and a constructor default.
import { viaCall } from "./fit";
import { use } from "./call";

console.log(`${viaCall(1)} ${use(4)}`);
