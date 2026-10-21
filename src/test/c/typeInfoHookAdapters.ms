import { compileToC, compileProjectToC } from "../helpers";
import { MapEntry } from "../../module/loader";

function slotValues(c: string, slot: string): string[] {
	const out: string[] = [];
	const marker = "." + slot + " = ";
	let from = 0;
	while (true) {
		const at = c.indexOf(marker, from);
		if (at < 0) return out;
		const start = at + marker.length;
		const end = c.indexOf(",", start);
		out.push(c.slice(start, end));
		from = end;
	}
	return out;
}

function hookSlots(c: string, slot: string): int32 {
	let count = 0;
	for (const value of slotValues(c, slot)) {
		if (value != "NULL") count += 1;
	}
	return count;
}

function unadaptedSlots(c: string, slot: string, params: string): string[] {
	const out: string[] = [];
	for (const value of slotValues(c, slot)) {
		if (value != "NULL" && !c.contains(`static void ${value}(${params}) {`)) out.push(value);
	}
	return out;
}

test "every TypeInfo destroy and trace slot holds an adapter with the slot's exact signature" {
	const c = compileToC(`
		class Node {
			name: string;
			next: Node | null = null;
			constructor(name: string) { this.name = name; }
		}
		function ring(): int32 {
			const a = new Node("a");
			const b = new Node("b");
			a.next = b;
			b.next = a;
			return a.name.length + b.name.length;
		}
		function counter(): () => number {
			let xs: int32[] = [1, 2, 3];
			return () => { xs.push(4); return xs.length; };
		}
		const f = counter();
		console.log(ring(), f());
	`);
	assert c.ok;
	assert hookSlots(c.value, "destroyFn") >= 2;
	assert hookSlots(c.value, "traceFn") >= 1;
	assert unadaptedSlots(c.value, "destroyFn", "void* dest").length == 0;
	assert unadaptedSlots(c.value, "traceFn", "void* dest, void* env").length == 0;
}

test "a Promise.all cell of structs and a cross-module class adapt their TypeInfo hooks in the owning module" {
	const entries: MapEntry[] = [
		{ entryPath: "src/tag.ms", entrySource: `
			export struct Tag { label: string; n: int32; }
			export class Holder { tag: string; constructor(t: string) { this.tag = t; } }
			export async function mk(l: string, n: int32): Promise<Tag> { return { label: l, n }; }
		` },
		{ entryPath: "src/main.ms", entrySource: `
			import { Tag, Holder, mk } from "./tag";
			async function main(): Promise<void> {
				const ts = await Promise.all([mk("a", 1), mk("b", 2)]);
				const h = new Holder(ts[0].label);
				console.log(h.tag + ts[1].label);
			}
			main();
		` },
	];
	const c = compileProjectToC(entries, "src/main.ms");
	assert !c.startsWith("ERROR:");
	assert c.contains(".name = \"TagArrayRefCell\"");
	assert hookSlots(c, "destroyFn") >= 2;
	assert unadaptedSlots(c, "destroyFn", "void* dest").length == 0;
	assert unadaptedSlots(c, "traceFn", "void* dest, void* env").length == 0;
}
