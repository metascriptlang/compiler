// @stdout: reexported 2 again 2 local 1 aliased 1
// note: `export { pick } from "./second"` exports second's pick even where the module has bound `pick` to first's by an import: a re-export names the declaration the source module exports, never a local binding that shares its name, and one declaration keeps every name it is exported under.

import { pick, again, local, firstPick } from "./hub";

console.log(`reexported ${pick()} again ${again()} local ${local()} aliased ${firstPick()}`);
