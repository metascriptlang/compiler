import { copyFile, exists } from "std/fs";
import { exit, platform } from "std/process";
import { reload, reloadKindName } from "std/hcr";
import { total } from "./logic";

const EXT = platform == "windows" ? ".dll" : platform == "darwin" ? ".dylib" : ".so";

console.log(`HCR-ARRAY first ${total()}`);
if (exists(`g2/module.logic${EXT}`)) {
	for (const name of [`module.logic${EXT}`, `module${EXT}.hcrabi`]) {
		if (!copyFile(`g2/${name}`, `run/${name}`).ok) {
			console.log(`HCR-ARRAY cannot place g2/${name}`);
			exit(1);
		}
	}
	console.log(`HCR-ARRAY ${reloadKindName(reload())} ${total()}`);
}
