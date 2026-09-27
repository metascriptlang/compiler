import { copyFile } from "std/fs";
import { exit, platform } from "std/process";
import { reload, reloadKindName } from "std/hcr";
import { record, describe } from "./logic";

const EXT = platform == "windows" ? ".dll" : platform == "darwin" ? ".dylib" : ".so";

record(1);
record(2);
console.log(`HCR-KINDS before: ${describe()}`);
for (const name of [`module.logic${EXT}`, `module${EXT}.hcrabi`]) {
	if (!copyFile(`g2/${name}`, `run/${name}`).ok) exit(1);
}
const outcome = reload();
console.log(`HCR-KINDS reload: ${reloadKindName(outcome.kind)}`);
console.log(`HCR-KINDS after: ${describe()}`);
