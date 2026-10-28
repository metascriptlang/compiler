// @stdout: 2 2 2 3 7 2 0
// @stdout: 2 2 2
struct Pt { x: int32; y: int32; }
function run(): void {
	const s = new Set<int32>([1, 2]);
	const t = new Set<string>(["p", "q"]);
	const m = new Map<string, int32>([["a", 1], ["b", 2], ["a", 3]]);
	const h = new HashMap<string, int32>([["x", 7]]);
	const hs = new HashSet<int32>([5, 5, 6]);
	const e = new Map<string, int32>();
	console.log(s.size, t.size, m.size, m.get("a"), h.get("x"), hs.size, e.size);
	const a = new Map<int32, string[]>([[1, ["u", "v"]], [2, []]]);
	const b = new Map<string, Pt>([["o", { x: 1, y: 2 }]]);
	const src: int32[] = [3, 4, 3];
	console.log(a.get(1)!.length, b.get("o")!.y, new Set<int32>(src).size);
}
run();
