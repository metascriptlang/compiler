// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: nspace 4 4 42 true 3 8 id
// note: `import * as ns` exposes a module's exports through member access. A class reached as `ns.K` had no methods (the importer registered the extension entries of class methods only for named imports: "Property 'get' does not exist on type 'K'" on both backends), and multi-file JS emitted a bare side-effect import, so `ns` was undefined at run time.
import * as ns from "./lib";

const k = new ns.K(3);
const fp = ns.f;
console.log(`nspace ${ns.f(2)} ${ns.twiceF(1)} ${ns.LIMIT} ${ns.Color.Red == ns.Color.Red} ${k.get()} ${fp(4)} ${ns.id("id")}`);
