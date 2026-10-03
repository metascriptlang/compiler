import { exists, copyFile } from "std/fs";
import { exit, platform } from "std/process";
import { reload, reloadKindName } from "std/hcr";
import { probe } from "./logic";

const EXT = platform == "windows" ? ".dll" : platform == "darwin" ? ".dylib" : ".so";

console.log(`HCR-INST first ${probe()}`);
if (exists(`g2/module.logic${EXT}`)) {
	for (const name of [`module.logic${EXT}`, `module${EXT}.hcrabi`]) {
		if (!copyFile(`g2/${name}`, `run/${name}`).ok) {
			console.log(`HCR-INST cannot place g2/${name}`);
			exit(1);
		}
	}
	const kind = reload();
	console.log(`HCR-INST ${reloadKindName(kind)} ${probe()}`);
}
