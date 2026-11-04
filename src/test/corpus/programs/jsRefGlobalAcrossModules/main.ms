// @stdout: 2 1 3 2 3
// @stdout: 12 11 23 12 23
// @stdout: 113 11 124 124
// @stdout: 2125 1011 2125 22
// note: an exported `let` that a `ref` parameter takes is one cell on JS, read and written through by every importer:
// a named import, a namespace import, an importer writing a field, an importer passing it `ref` itself, and a re-export through a hub.
import { bumpInOwner, pools } from "./pool";
import { readNamed, readTotal } from "./read";
import { bumpInImporter } from "./byRef";
import { readThroughNamespace } from "./ns";
import { writeFields } from "./write";
import { readViaHub, bumpViaHub } from "./viaHub";

bumpInOwner();
console.log(readNamed(), readTotal(), readThroughNamespace(), readNamed(), readViaHub());
bumpInImporter();
console.log(readNamed(), readTotal(), readThroughNamespace(), readNamed(), readViaHub());
writeFields();
console.log(readNamed(), readTotal(), readThroughNamespace(), readViaHub());
bumpViaHub();
console.log(readViaHub(), readTotal(), readThroughNamespace(), pools[0].count + pools.length + 10);
