import { copyFile } from "std/fs";
import { exit, platform } from "std/process";
import { reload, lastReload, ReloadResult } from "std/hcr";

const EXT = platform == "windows" ? ".dll" : platform == "darwin" ? ".dylib" : ".so";

export function change(generation: string, moduleIds: string[]): ReloadResult {
	for (const moduleId of moduleIds) {
		const name = `module.${moduleId}${EXT}`;
		if (!copyFile(`${generation}/${name}`, `run/${name}`).ok) exit(1);
	}
	const bundle = `module${EXT}.hcrabi`;
	if (!copyFile(`${generation}/${bundle}`, `run/${bundle}`).ok) exit(1);
	reload();
	return lastReload();
}
