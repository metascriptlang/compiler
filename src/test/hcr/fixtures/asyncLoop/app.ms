import { copyFile } from "std/fs";
import { exit, platform } from "std/process";
import { reload, reloadKindName } from "std/hcr";
import { value } from "./logic";

const EXT = platform == "windows" ? ".dll" : platform == "darwin" ? ".dylib" : ".so";

function place(name: string): void {
	if (!copyFile(`g2/${name}`, `run/${name}`).ok) {
		console.log(`HCR-ASYNC cannot place g2/${name}`);
		exit(1);
	}
}

async function frames(count: int32): Promise<int32> {
	let seen: int32 = 0;
	for (let frame: int32 = 0; frame < count; frame += 1) {
		await sleepAsync(1);
		if (frame == 1) {
			place(`module.logic${EXT}`);
			place(`module${EXT}.hcrabi`);
		}
		console.log(`HCR-ASYNC frame ${frame}: ${reloadKindName(reload())} value ${value()}`);
		seen += 1;
	}
	return seen;
}

async function failLater(): Promise<int32> {
	await sleepAsync(1);
	throw new Error("left unhandled");
}

frames(3).then((seen: int32): void => {
	console.log(`HCR-ASYNC done ${seen}`);
	failLater();
});
