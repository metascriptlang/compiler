// note: Promise.all collects every element type into an ordinary array that owns its elements, and a value union travels through a future like a struct.

class Box { v: int32 = 0; }
interface Tag { name: string; n: int32; }
struct Pair { n: int32; tag: string; }
type Count = () => int32;

async function counter(start: int32): Promise<Count> {
	let seen = start;
	return (): int32 => { seen = seen + 1; return seen; };
}
async function word(n: int32): Promise<string> { return `w${n}`; }
async function box(n: int32): Promise<Box> { const b = new Box(); b.v = n; return b; }
async function boxOrInt(n: int32): Promise<Box | int32> {
	if (n > 0) { const b = new Box(); b.v = n; return b; }
	return n;
}
async function wordOrInt(n: int32): Promise<string | int32> {
	if (n > 0) return `s${n}`;
	return n;
}
async function pair(n: int32): Promise<[Box, int32]> { const b = new Box(); b.v = n; return [b, n * 10]; }
async function tag(n: int32): Promise<Tag> { return { name: `t${n}`, n }; }
async function pairStruct(n: int32): Promise<Pair> { return { n, tag: `p${n}` }; }
async function row(n: int32): Promise<int32[]> { return [n, n + 1]; }

function boxOrIntValue(u: Box | int32): int32 {
	if (u instanceof Box) return u.v;
	return u;
}
function wordOrIntText(u: string | int32): string {
	if (typeof u === "string") return u;
	return `${u}`;
}

async function runClosures(rounds: int32): Promise<int32> {
	let sum = 0;
	for (let i = 0; i < rounds; i += 1) {
		const cs = await Promise.all([counter(i), counter(i + 1)]);
		sum += cs.length + cs[0]() + cs[1]();
	}
	return sum;
}

async function runValues(rounds: int32): Promise<string> {
	let sum = 0;
	let text = "";
	for (let i = 0; i < rounds; i += 1) {
		const ws = await Promise.all([word(i), word(i + 1)]);
		text = ws[0] + ws[1];
		const bs = await Promise.all([box(i), box(i + 2)]);
		sum += bs[0].v + bs[1].v;
		const us = await Promise.all([boxOrInt(i + 1), boxOrInt(-i)]);
		sum += us.length + boxOrIntValue(us[0]) + boxOrIntValue(us[1]);
		const ss = await Promise.all([wordOrInt(i + 1), wordOrInt(-i)]);
		text = text + wordOrIntText(ss[0]) + wordOrIntText(ss[1]);
		const ps = await Promise.all([pair(i), pair(i + 1)]);
		sum += ps.length + ps[0][0].v + ps[1][1];
		const ts = await Promise.all([tag(i), tag(i + 3)]);
		text = text + ts[0].name + ts[1].name;
		sum += ts[1].n;
		const qs = await Promise.all([pairStruct(i), pairStruct(i + 4)]);
		text = text + qs[1].tag;
		sum += qs[0].n;
		const lone = await boxOrInt(i + 7);
		sum += boxOrIntValue(lone);
		const loneWord = await wordOrInt(i);
		text = text + wordOrIntText(loneWord);
		const rs = await Promise.all([row(i), row(i + 5)]);
		sum += rs.length + rs[0][1] + rs[1][0];
	}
	return `${sum} ${text}`;
}

console.log(`closures ${await runClosures(1)} ${await runClosures(50)}`);
console.log(`values ${await runValues(1)}`);
console.log(`values ${await runValues(50)}`);
