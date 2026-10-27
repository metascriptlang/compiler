// @stdout: 2 2 2
// @stdout: 12 12
// note: an exported `let` that a `ref` parameter takes is one cell on JS, read through by every importer:
// a named import, a namespace import, and an importer that passes it `ref` itself.
import { bumpInOwner } from "./pool";
import { readNamed } from "./read";
import { bumpInImporter } from "./byRef";
import { readThroughNamespace } from "./ns";

bumpInOwner();
console.log(readNamed(), readThroughNamespace(), readNamed());
bumpInImporter();
console.log(readNamed(), readThroughNamespace());
