// @stdout: swap=2,1 b,a|ref=21 q!p!|call=7,8 var=3,4|nest=1,2,3|tuple=2y|obj=12
class Item { v: int32 = 0; constructor(v: int32) { this.v = v; } }
interface Box { s: string; }
interface P { x: int32; y: int32; }
function mk(s: string): Box { return { s: s + "!" }; }
function pair(): int32[] { return [7, 8]; }
function swaps(): string {
	let m: int32 = 1;
	let n: int32 = 2;
	[m, n] = [n, m];
	let s = "a" + "";
	let t = "b" + "";
	[s, t] = [t, s];
	return "swap=" + m.toString() + "," + n.toString() + " " + s + "," + t;
}
function refs(): string {
	let a = new Item(1);
	let b = new Item(2);
	[a, b] = [b, a];
	const arr: Box[] = [mk("p"), mk("q")];
	[arr[0], arr[1]] = [arr[1], arr[0]];
	return "ref=" + (a.v * 10 + b.v).toString() + " " + arr[0].s + arr[1].s;
}
function sources(): string {
	let a: int32 = 0;
	let b: int32 = 0;
	[a, b] = pair();
	const first = a.toString() + "," + b.toString();
	const src: int32[] = [3, 4];
	[a, b] = src;
	return "call=" + first + " var=" + a.toString() + "," + b.toString();
}
function shapes(): string {
	let b: int32 = 0;
	let c: int32 = 0;
	let d: int32 = 0;
	[b, [c, d]] = [1, [2, 3]];
	let n: int32 = 1;
	let w = "x";
	[n, w] = [2, "y"];
	let x: int32 = 0;
	let y: int32 = 0;
	const p: P = { x: 1, y: 2 };
	({ x, y } = p);
	return "nest=" + b.toString() + "," + c.toString() + "," + d.toString()
		+ "|tuple=" + n.toString() + w + "|obj=" + x.toString() + y.toString();
}
function run(): void {
	console.log(swaps() + "|" + refs() + "|" + sources() + "|" + shapes());
}
run();
