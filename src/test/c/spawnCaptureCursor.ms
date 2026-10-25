import { compileToC } from "../helpers";

const PROGRAM = `
class Item { v: int32 = 0; next: Item | null = null; }
class Leaf { v: int32 = 0; }
function viaCapture(items: Readonly<Item[]>): int32 {
	const best = items[3];
	const ok = (x: Readonly<Item>): boolean => x.v >= best.v;
	let n: int32 = 0;
	for (const x of items) if (ok(x)) n += 1;
	return n;
}
function leafCapture(leaves: Readonly<Leaf[]>): int32 {
	const pick = leaves[1];
	const ok = (x: Readonly<Leaf>): boolean => x.v >= pick.v;
	let n: int32 = 0;
	for (const x of leaves) if (ok(x)) n += 1;
	return n;
}
function nested(items: Readonly<Item[]>): int32 {
	const best = items[3];
	const outer = (x: Readonly<Item>): boolean => {
		const inner = (): boolean => x.v >= best.v;
		return inner();
	};
	let n: int32 = 0;
	for (const x of items) if (outer(x)) n += 1;
	return n;
}
function returned(items: Item[]): () => int32 {
	const kept = items[0];
	const get = (): int32 => kept.v;
	return get;
}
const sink: (() => int32)[] = [];
function pushed(items: Item[]): int32 {
	const held = items[0];
	sink.push((): int32 => held.v);
	return sink.length;
}
async function round(items: Item[], leaves: Leaf[]): Promise<int32> {
	const a = spawn((): int32 => {
		const best = items[3];
		const ok = (x: Readonly<Item>): boolean => x.v >= best.v && items.length > 0;
		let n: int32 = 0;
		for (const x of items) if (ok(x)) n += 1;
		return n;
	});
	const b = spawn((): int32 => viaCapture(items) + leafCapture(leaves) + nested(items));
	return await a + await b;
}
const items: Item[] = [];
const leaves: Leaf[] = [];
for (let i = 0; i < 8; i++) { const it = new Item(); it.v = i as int32; items.push(it); const l = new Leaf(); l.v = i as int32; leaves.push(l); }
console.log(\`\${await round(items, leaves)} \${returned(items)()} \${pushed(items)}\`);
`;

function envInfos(prefix: string): string[] {
	const r = compileToC(PROGRAM);
	const c = r.ok ? r.value : "";
	const out: string[] = [];
	for (const line of c.split("\n")) {
		if (line.startsWith(`msTypeInfo dollarEnv_${prefix}`)) out.push(line);
	}
	return out;
}

function countsNothing(info: string): boolean {
	return info.contains(".traceFn = NULL") && info.contains(".destroyFn = NULL");
}

test "E2E C: a closure called in its routine holds a view of a lent cyclic graph without a count" {
	const infos = envInfos("viaCapture_");
	assert infos.length == 1;
	assert countsNothing(infos[0]);
}

test "E2E C: a closure called in its routine holds a view of a lent acyclic element without a count" {
	const infos = envInfos("leafCapture_");
	assert infos.length == 1;
	assert countsNothing(infos[0]);
}

test "E2E C: a closure nested in a called closure reaches its parameter and the outer view without a count" {
	const infos = envInfos("nested_");
	assert infos.length == 2;
	for (const info of infos) assert countsNothing(info);
}

test "E2E C: a closure called inside a task holds the view it reads of the lent graph without a count" {
	const infos = envInfos("round_fexpr");
	let closures = 0;
	for (const info of infos) {
		if (!info.contains("_arrow")) continue;
		closures += 1;
		assert countsNothing(info);
	}
	assert closures == 1;
}

test "E2E C: a returned closure still counts the element it captured" {
	const infos = envInfos("returned_");
	assert infos.length == 1;
	assert !countsNothing(infos[0]);
	assert infos[0].contains("RttiDestroy");
}

test "E2E C: a closure pushed into a module array still counts the element it captured" {
	const infos = envInfos("pushed_");
	assert infos.length == 1;
	assert !countsNothing(infos[0]);
	assert infos[0].contains("RttiDestroy");
}
