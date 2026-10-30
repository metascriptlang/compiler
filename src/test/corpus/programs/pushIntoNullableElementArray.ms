// @stdout: true|true|true|true
const xs: (int32 | null)[] = [];
const n: int32 = 3;
xs.push(n);
xs.push(null);

const ys: (int32 | null)[] = [];
const hit: int32 | null = 3;
ys.push(hit);
ys.push(null);

const ss: (string | null)[] = [];
const s: string = "a";
ss.push(s);
ss.push(null);

const fs: (float32 | null)[] = [];
const f: float32 = 1.5;
fs.push(f);
fs.push(null);

console.log([
	xs.length === 2 && xs[0] === 3 && xs[1] === null,
	ys.length === 2 && ys[0] === 3 && ys[1] === null,
	ss.length === 2 && ss[0] === "a" && ss[1] === null,
	fs.length === 2 && fs[0] === 1.5 && fs[1] === null,
].join("|"));
