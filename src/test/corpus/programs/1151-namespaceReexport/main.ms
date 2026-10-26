// @stdout: hi 42 3 7 6
// @exit: 0
// note: `export * as V from "./vals"` re-exports a module as one namespace binding (ES2020); an importer reads its values and names its types through it on every backend, and a namespace re-exported again keeps its members.

import { V } from "./hub";
import { Hub } from "./outer";

const p: V.Point = { x: 3, y: 4 };
const q: Hub.V.Point = { x: 5, y: 6 };
console.log(V.greeting, V.twice(21), p.x, Hub.V.twice(3) + 1, q.y);
