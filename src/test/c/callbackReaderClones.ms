import { compileToC } from "../helpers";

function bodyOf(code: string, fn: string): string {
	for (const line of code.split("\n")) {
		if (line.endsWith(" {") && line.indexOf(" " + fn + "__") >= 0) {
			const start = code.indexOf(line + "\n");
			return code.slice(start, code.indexOf("\n}", start));
		}
	}
	return "";
}

function count(text: string, token: string): int32 {
	return (text.split(token).length - 1) as int32;
}

const READERS = `
class Tree { v: int32 = 0; kids: Tree[] = []; tag: string = ""; }
struct Slot { item: Tree; w: int64; a: int64; b: int64; }
function forEachKid(t: Tree, cb: (k: Tree) => void): void {
	for (let i = 0; i < t.kids.length; i++) cb(t.kids[i]);
}
function sum(t: Tree): int32 {
	let s = t.v;
	forEachKid(t, (k: Tree): void => { s += sum(k); });
	return s;
}
function pruneParent(t: Tree): int32 {
	let seen: int32 = 0;
	forEachKid(t, (k: Tree): void => {
		if (seen == 0) t.kids = [];
		seen += k.tag.length as int32;
	});
	return seen;
}
function eachSlot(xs: Slot[], cb: (s: Slot) => int64): int64 {
	let n: int64 = 0;
	for (let i = 0; i < xs.length; i++) n += cb(xs[i]);
	return n;
}
function countIf<T>(this arr: Readonly<T[]>, fn: (x: Readonly<T>) => boolean): int32 {
	let n: int32 = 0;
	for (let i = 0; i < arr.length; i++) if (fn(arr[i])) n += 1;
	return n;
}
function lastWhere(xs: Tree[], fn: (t: Tree) => boolean): int32 {
	for (let i = xs.length - 1; i >= 0; i--) if (fn(xs[i])) return i as int32;
	return -1;
}
function anyOf(xs: Tree[], fn: (t: Tree) => boolean): boolean {
	return lastWhere(xs, fn) >= 0;
}
const root = new Tree();
for (let i = 0; i < 3; i++) root.kids.push(new Tree());
const slots: Slot[] = [{ item: root, w: 1, a: 0, b: 0 }];
console.log(sum(root) + pruneParent(root));
console.log(eachSlot(slots, (s: Slot): int64 => s.w + s.item.v as int64));
console.log(root.kids.countIf((k: Readonly<Tree>): boolean => k.v > 0));
console.log(anyOf(root.kids, (k: Tree): boolean => k.v == 2));
`;

function compiled(): string {
	const result = compileToC(READERS);
	if (!result.ok) throw new Error(result.error);
	return result.value;
}

test "a reader whose callback keeps its contract holds the element it lends uncounted" {
	const code = compiled();
	const general = bodyOf(code, "forEachKid");
	const lent = bodyOf(code, "forEachKiddollarlent_");
	assert count(general, "msIncref") == 1, general;
	assert lent != "" && count(lent, "msIncref") == 0 && count(lent, "msDecref") == 0, lent;
}

test "a callback that writes nothing the reader holds runs the reader clone, one that frees it runs the general body" {
	const code = compiled();
	const sum = bodyOf(code, "sum");
	const prune = bodyOf(code, "pruneParent");
	assert count(sum, "forEachKiddollarlent_") == 1, sum;
	assert count(prune, "forEachKiddollarlent_") == 0 && count(prune, "forEachKid__") == 1, prune;
}

test "a struct element lent to a callback is neither copied nor counted in the reader clone" {
	const code = compiled();
	assert count(bodyOf(code, "eachSlot"), "Copy(") == 1;
	const lent = bodyOf(code, "eachSlotdollarlent_");
	assert lent != "" && count(lent, "Copy(") == 0 && count(lent, "msIncref") == 0, lent;
}

test "a generic reader instance gets a clone that counts nothing" {
	const code = compiled();
	let lent = "";
	for (const line of code.split("\n")) {
		if (line.endsWith(" {") && line.indexOf("countIf") >= 0 && line.indexOf("dollarlent") >= 0) lent = line;
	}
	assert lent != "", "no countIf clone";
	const body = code.slice(code.indexOf(lent + "\n"), code.indexOf("\n}", code.indexOf(lent + "\n")));
	assert count(body, "msIncref") == 0, body;
}

test "a reader that forwards its callback calls the clone of the reader it forwards to" {
	const code = compiled();
	const lent = bodyOf(code, "anyOfdollarlent_");
	assert count(lent, "lastWheredollarlent_") == 1, lent;
	assert count(bodyOf(code, "anyOf"), "lastWheredollarlent_") == 0;
	assert count(bodyOf(code, "lastWheredollarlent_"), "msIncref") == 0;
}
