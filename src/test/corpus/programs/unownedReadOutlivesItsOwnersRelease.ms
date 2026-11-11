// @stdout: interface global n1
// @stdout: interface field n2
// @stdout: record field n3
// @stdout: class global n4
// @stdout: unknown global n5
// @stdout: union global n6
// @stdout: closure env n7
// @stdout: hook n8
// @stdout: tuple n9
// @stdout: struct element n10
// @stdout: owned element n11
// @stdout: map value n12
// note: a value read through an Unowned<T> edge stays alive while it is used, whatever holds the target's last strong reference and whatever call releases it: a slot typed by an interface or an unnamed record the class fits, a class, unknown or union slot, a closure's environment, another object's onDestroy, a tuple, a struct element, an Owned element or a Map value.
class N {
	name: string;
	constructor(name: string) { this.name = name; }
}
class H { at: Unowned<N> | null = null; }
function mk(k: int32): N { return new N("n" + k.toString()); }

interface Named { name: string; }
class Slots {
	named: Named | null = null;
	record: { name: string } | null = null;
}
let namedSlot: Named | null = null;
let classSlot: N | null = null;
let unknownSlot: unknown = null;
let unionSlot: N | string = "none";
let envSlot: (() => string) | null = null;
let tupleSlot: [N, int32] | null = null;
struct Pair { n: N; }
const pairs: Pair[] = [];
class Tree { kids: Owned<N>[] = []; }
const tree = new Tree();
const byKey = new Map<string, N>();
class Trigger { tag: int32 = 1; }
let registry: N[] = [];
let trigger: Trigger | null = null;
function onDestroy(this t: Trigger): void { registry = []; }

function emptyNamedSlot(): void { namedSlot = null; }
function emptyNamedField(s: Slots): void { s.named = null; }
function emptyRecordField(s: Slots): void { s.record = null; }
function emptyClassSlot(): void { classSlot = null; }
function emptyUnknownSlot(): void { unknownSlot = null; }
function emptyUnionSlot(): void { unionSlot = "gone"; }
function dropEnv(): void { envSlot = null; }
function dropTrigger(): void { trigger = null; }
function emptyTuple(): void { tupleSlot = null; }
function popPair(): void { pairs.pop(); }
function popKid(): void { tree.kids.pop(); }
function deleteKey(): void { byKey.delete("k"); }

function viaNamedSlot(h: H): string {
	const p = h.at;
	emptyNamedSlot();
	return p != null ? p.name : "none";
}
function viaNamedField(h: H, s: Slots): string {
	const p = h.at;
	emptyNamedField(s);
	return p != null ? p.name : "none";
}
function viaRecordField(h: H, s: Slots): string {
	const p = h.at;
	emptyRecordField(s);
	return p != null ? p.name : "none";
}
function viaClassSlot(h: H): string {
	const p = h.at;
	emptyClassSlot();
	return p != null ? p.name : "none";
}
function viaUnknownSlot(h: H): string {
	const p = h.at;
	emptyUnknownSlot();
	return p != null ? p.name : "none";
}
function viaUnionSlot(h: H): string {
	const p = h.at;
	emptyUnionSlot();
	return p != null ? p.name : "none";
}
function viaEnv(h: H): string {
	const p = h.at;
	dropEnv();
	return p != null ? p.name : "none";
}
function viaHook(h: H): string {
	const p = h.at;
	dropTrigger();
	return p != null ? p.name : "none";
}
function viaTuple(h: H): string {
	const p = h.at;
	emptyTuple();
	return p != null ? p.name : "none";
}
function viaPair(h: H): string {
	const p = h.at;
	popPair();
	return p != null ? p.name : "none";
}
function viaKid(h: H): string {
	const p = h.at;
	popKid();
	return p != null ? p.name : "none";
}
function viaKey(h: H): string {
	const p = h.at;
	deleteKey();
	return p != null ? p.name : "none";
}

const slots = new Slots();
const holders: H[] = [];
for (let i = 0; i < 12; i += 1) holders.push(new H());

function arm(): void {
	const a = mk(1);
	holders[0].at = a;
	namedSlot = a;
	const b = mk(2);
	holders[1].at = b;
	slots.named = b;
	const c = mk(3);
	holders[2].at = c;
	slots.record = c;
	const d = mk(4);
	holders[3].at = d;
	classSlot = d;
	const e = mk(5);
	holders[4].at = e;
	unknownSlot = e;
	const f = mk(6);
	holders[5].at = f;
	unionSlot = f;
	const g = mk(7);
	holders[6].at = g;
	envSlot = (): string => g.name;
	const k = mk(8);
	holders[7].at = k;
	registry = [k];
	trigger = new Trigger();
	const l = mk(9);
	holders[8].at = l;
	tupleSlot = [l, 1];
	const m = mk(10);
	holders[9].at = m;
	pairs.push({ n: m });
	const o = mk(11);
	holders[10].at = o;
	tree.kids.push(o);
	const q = mk(12);
	holders[11].at = q;
	byKey.set("k", q);
}
arm();

console.log("interface global " + viaNamedSlot(holders[0]));
console.log("interface field " + viaNamedField(holders[1], slots));
console.log("record field " + viaRecordField(holders[2], slots));
console.log("class global " + viaClassSlot(holders[3]));
console.log("unknown global " + viaUnknownSlot(holders[4]));
console.log("union global " + viaUnionSlot(holders[5]));
console.log("closure env " + viaEnv(holders[6]));
console.log("hook " + viaHook(holders[7]));
console.log("tuple " + viaTuple(holders[8]));
console.log("struct element " + viaPair(holders[9]));
console.log("owned element " + viaKid(holders[10]));
console.log("map value " + viaKey(holders[11]));
