// @stdout: p256 2 8 3 32 | q 9 1 | a,b,c | 5
struct Lim { words: int32; m: uint32[3]; }
interface Shape { name: string; tag: uint8[]; lim: Lim; size: int32; }
interface Loose { name: string; lim: Lim; }

const NAME = "p256";
const SIZE = 32;
const LIM: Lim = { words: 3, m: [1, 2, 3] };
const A = "a";

export const shape: Readonly<Shape> = { name: NAME, tag: [7, 8], lim: LIM, size: SIZE };
const loose: Loose = { name: "q", lim: { words: 9, m: [1, 0, 0] } };
const letters: string[] = [A, "b"];

function tagSum(s: Readonly<Shape>): int32 {
	let sum = 0;
	for (const b of s.tag) sum += b;
	return sum - 10;
}

letters.push("c");
loose.lim = { words: 9, m: [loose.lim.m[0], 0, 0] };
console.log(`${shape.name} ${shape.tag.length} ${shape.tag[1]} ${shape.lim.m[2]} ${shape.size} | ${loose.name} ${loose.lim.words} ${loose.lim.m[0]} | ${letters.join(",")} | ${tagSum(shape)}`);
