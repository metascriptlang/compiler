import { compileProjectToC } from "../helpers";
import { MapEntry } from "../../module/loader";

function occurrences(haystack: string, needle: string): int32 {
	let count = 0;
	let from = 0;
	while (true) {
		const at = haystack.indexOf(needle, from);
		if (at < 0) return count;
		count += 1;
		from = at + needle.length;
	}
	return count;
}

function lineAfter(haystack: string, marker: string): string {
	const at = haystack.indexOf(marker, 0);
	if (at < 0) return "";
	const rest = haystack.slice(at, haystack.length);
	const line = rest.indexOf("#line", 0);
	if (line < 0) return "";
	const end = rest.indexOf("\n", line);
	return rest.slice(line, end);
}

test "a foreign type's hooks are defined in its declaring module, not in the module that stores it" {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: `
			export function wrap<T>(x: T): T[] {
				const out: T[] = [];
				out.push(x);
				return out;
			}
		` },
		{ entryPath: "src/main.ms", entrySource: `
			import { wrap } from "./lib";
			interface Item { name: string; }
			function run(): void {
				const it: Item = { name: "n" };
				const items = wrap(it);
				console.log(items[0].name);
			}
			run();
		` },
	];
	const c = compileProjectToC(entries, "src/main.ms");
	assert !c.startsWith("ERROR:");
	assert occurrences(c, "Destroy(Item__") >= 1;
	const origin = lineAfter(c, "Destroy(Item__");
	assert origin.contains("main.ms");
	assert !origin.contains("lib.ms");
}
