// @stdout: 2 3 3 3 1,2 true | 2 3 3 3 1,2 true | 2 3 3 3 1,2 true # abc a-b-c | ac a-c # 2 6 t hi 5 | -1 -1 f d 0 | 2 -1 t ok 0 # y n # s2 n4 3 # 2s 6q
// @xfail(raiser): the Raiser VM has no Array.join (inbox 2026-09-24-int-array-literal-has-no-sort-or-join) and reads an absent-vs-present nullable string as falsy when present; the alias-free twin fails the same
type Brand<T> = T;
function mk<T>(o: T): Brand<T> { return o; }

interface P { a: number; b: string }

function nums(xs: Brand<number[]>): string {
	xs.push(3);
	const last = xs.pop();
	let t: number = 0;
	for (const e of xs) t = t + e;
	const more = [...xs, 9];
	return `${xs.length} ${last} ${t} ${more.length} ${xs.join(",")} ${xs.includes(2)}`;
}

function strs(xs: Brand<string[]>): string {
	xs.push("c");
	let t = "";
	for (const e of xs) t = t + e;
	return `${t} ${xs.join("-")}`;
}

function nullable(s: Brand<string | null>, n: Brand<number | null>): string {
	const len = s !== null ? s.length : -1;
	const sum = n !== null ? n + 1 : -1;
	const truthy = s ? "t" : "f";
	return `${len} ${sum} ${truthy} ${s ?? "d"} ${n ?? 0}`;
}

function flag(b: Brand<boolean>): string {
	return b ? "y" : "n";
}

function union(u: Brand<string | number>): string {
	if (typeof u === "string") return `s${u.length}`;
	return `n${u}`;
}

function field(p: Brand<P>): string {
	p.a = p.a + 1;
	const { b } = p;
	return `${p.a}${b}`;
}

const arr = mk<number[]>([1, 2]);
const annotArr: Brand<number[]> = [1, 2];
const deep = mk<Brand<number[]>>([1, 2]);
const out: string[] = [];
out.push(`${nums(arr)} | ${nums(annotArr)} | ${nums(deep)}`);
out.push(`${strs(mk<string[]>(["a", "b"]))} | ${strs(["a"])}`);
const hi: Brand<string | null> = "hi";
const none: Brand<string | null> = null;
const five: Brand<number | null> = 5;
out.push(`${nullable(hi, five)} | ${nullable(none, null)} | ${nullable(mk<string | null>("ok"), mk<number | null>(null))}`);
out.push(`${flag(true)} ${flag(mk<boolean>(false))}`);
const assigned: Brand<string | number> = "abc";
out.push(`${union("xy")} ${union(mk<string | number>(4))} ${typeof assigned === "string" ? assigned.length : -1}`);
const pt: Brand<P> = { a: 1, b: "s" };
out.push(`${field(pt)} ${field(mk<P>({ a: 5, b: "q" }))}`);
console.log(out.join(" # "));
