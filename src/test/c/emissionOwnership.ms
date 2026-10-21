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

function promiseAllCellTypeInfo(c: string): string {
	const at = c.indexOf("MS_PROMISE_ALL_FOR_TI(", 0);
	if (at < 0) return "";
	const end = c.indexOf(");", at);
	const amp = c.lastIndexOf("&", end);
	return amp < at ? "" : c.slice(amp + 1, end);
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

test "a Promise.all result is an array cell with one TypeInfo definition however many modules collect into it" {
	const entries: MapEntry[] = [
		{ entryPath: "src/tag.ms", entrySource: `
			export struct Tag { label: string; n: int32; }
			export async function mk(l: string, n: int32): Promise<Tag> { return { label: l, n }; }
		` },
		{ entryPath: "src/other.ms", entrySource: `
			import { Tag, mk } from "./tag";
			export async function gather(): Promise<int32> {
				const ts = await Promise.all([mk("c", 1), mk("d", 2)]);
				return ts.length;
			}
		` },
		{ entryPath: "src/main.ms", entrySource: `
			import { Tag, mk } from "./tag";
			import { gather } from "./other";
			async function main(): Promise<void> {
				const ts = await Promise.all([mk("a", 1), mk("b", 2)]);
				console.log(ts[0].label + ts[1].label + (await gather()).toString());
			}
			main();
		` },
	];
	const c = compileProjectToC(entries, "src/main.ms");
	assert !c.startsWith("ERROR:");
	assert occurrences(c, "MS_PROMISE_ALL_FOR_TI(") == 2;
	const ti = promiseAllCellTypeInfo(c);
	assert ti.endsWith("RefCellTypeInfo");
	assert occurrences(c, "\nmsTypeInfo " + ti + " = ") == 1;
	assert occurrences(c, "extern msTypeInfo " + ti + ";") >= 1;
	assert !c.contains("_allArrTI");
}
