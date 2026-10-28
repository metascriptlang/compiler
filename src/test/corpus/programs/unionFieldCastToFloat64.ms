// @stdout: 60 7 n 61
interface Box {
	left?: number | string | null;
	top: number | string | null;
	name?: number | string | null;
}
const b: Box = { left: 60, top: 7, name: "n" };
const x = b.left as float64;
const t = b.top as float64;
const s = b.name as string;
const w: number | string | null = 61;
const y = w as float64;
console.log(`${x} ${t} ${s} ${y}`);
