// nim-guard: `splice(start, deleteCount, item)` takes the deleted elements out of the array and
// inserts the item before it releases them, so an onDestroy run by that release that walks the
// array finds its final contents, never itself or an element released before it.
//
// Nim's seq delete shifts the tail down with `x[j] = move(x[j+1])`, whose sink releases an acyclic
// element before it stores (system.nim delete; liftdestructors.nim atomicRefOp, attachedSink);
// NIM-REF records the forced divergence: the hook met its own dying element and the one released
// before it (ASan heap-use-after-free on MS).
//
// RED MEANS a hook saw contents other than the array's final ones, or the walk crashed on an
// element already released. The many-elements case deletes more than the runtime keeps inline.

class Witness {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void {
		if (!watching) return;
		const seen = viewer();
		if (seen != want) failures = `${failures}${what}: the hook of ${this.tag} saw [${seen}], want [${want}]; `;
		released = released + 1;
	}
}

let watching = false;
let what = "";
let want = "";
let released: int32 = 0;
let failures = "";
let viewer: () => string = (): string => "";

let ws: Witness[] = [];
let maybeWs: (Witness | null)[] = [];

function tagsOf(a: Witness[]): string {
	let s = "";
	for (const w of a) s = s == "" ? `${w.tag}` : `${s},${w.tag}`;
	return s;
}

function maybeTagsOf(a: (Witness | null)[]): string {
	let s = "";
	for (const w of a) {
		const t = w == null ? "null" : `${w.tag}`;
		s = s == "" ? t : `${s},${t}`;
	}
	return s;
}

function witnesses(n: int32): Witness[] {
	const a: Witness[] = [];
	for (let i: int32 = 1; i <= n; i++) a.push(new Witness(i));
	return a;
}

function start(name: string, final: string): void {
	what = name;
	want = final;
	released = 0;
	watching = true;
}

function expectReleased(n: int32): void {
	watching = false;
	if (released != n) failures = `${failures}${what}: released ${released}, want ${n}; `;
}

function replaceAt<T>(a: T[], i: number, x: T): void {
	a.splice(i, 1, x);
}

viewer = (): string => tagsOf(ws);

ws = witnesses(3);
start("one replaced", "1,9,3");
ws.splice(1, 1, new Witness(9));
expectReleased(1);

ws = witnesses(4);
start("two replaced", "9,3,4");
ws.splice(0, 2, new Witness(9));
expectReleased(2);

ws = witnesses(3);
start("tail clamped", "1,9");
ws.splice(1, 5, new Witness(9));
expectReleased(2);

ws = witnesses(12);
start("many replaced", "1,99,12");
ws.splice(1, 10, new Witness(99));
expectReleased(10);

ws = witnesses(3);
start("generic body", "9,2,3");
replaceAt(ws, 0, new Witness(9));
expectReleased(1);

ws = [];
viewer = (): string => maybeTagsOf(maybeWs);
maybeWs = [new Witness(1), null, new Witness(3)];
start("nullable elements", "null,3");
maybeWs.splice(0, 2, null);
expectReleased(1);
maybeWs = [];

if (failures != "") throw new Error(failures);
console.log("splice releases after the array holds its final contents");
