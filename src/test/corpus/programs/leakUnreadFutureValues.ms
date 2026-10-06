// @maxrss: 12
// @stdout: unread futures done
// note: A future nobody awaits owns its value and drops it with itself. Before futures owned their values, 300000 unread Promise<string> grew RSS to 20.8 MB and Promise<Box> to 11.1 MB while Promise<int32> stayed at 1.5 MB. Each tier with a heap payload is covered: string, struct with a string field, class, array, closure.

struct Pair { n: int32; tag: string; }
class Box { v: int32 = 0; tag: string = ""; }
type Label = () => string;

async function makeText(n: int32): Promise<string> { return "a text long enough to own a heap payload " + n.toString(); }
async function makePair(n: int32): Promise<Pair> { return { n: n, tag: "a pair tag long enough to own a payload " + n.toString() }; }
async function makeBox(n: int32): Promise<Box> { const b = new Box(); b.v = n; b.tag = "box " + n.toString(); return b; }
async function makeList(n: int32): Promise<int32[]> { return [n, n + 1, n + 2, n + 3]; }
async function makeLabel(n: int32): Promise<Label> { const owned = "label " + n.toString(); return (): string => owned; }

async function run(): Promise<void> {
	for (let i: int32 = 0; i < 100000; i = i + 1) {
		const a = makeText(i);
		const b = makePair(i);
		const c = makeBox(i);
		const d = makeList(i);
		const e = makeLabel(i);
	}
	for (let i: int32 = 0; i < 100000; i = i + 1) {
		makeText(i);
		makeBox(i);
	}
	console.log("unread futures done");
}

await run();
