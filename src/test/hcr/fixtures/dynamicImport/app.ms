import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { Note } from "./note";

const own = new Note("app");

function load(generation: string): void {
	const result = change(generation, ["lazy"]);
	console.log(`DYN ${generation}: ${reloadKindName(result.kind)} ${result.modules.join(",")}`);
}

async function run(): Promise<void> {
	const first = await import("./lazy");
	const again = await import("./lazy");
	console.log(`DYN lazy ${first.version()} ${first.ready} ${again.ready}`);
	load("g3");
	console.log(`DYN after g3 ${first.version()} ${first.ready}`);
	let failure: Error | null = null;
	try {
		const failed = await import("./failing");
		console.log(`DYN unexpected ${failed.value}`);
	} catch (e) {
		failure = e;
		console.log(`DYN first ${e.message}`);
	}
	try {
		await import("./failing");
		console.log("DYN unexpected second");
	} catch (e) {
		console.log(`DYN second ${e.message} ${e === failure ? "same" : "other"}`);
	}
}

console.log(`DYN start ${own.name}`);
load("g2");
run();
console.log("DYN sync end");
