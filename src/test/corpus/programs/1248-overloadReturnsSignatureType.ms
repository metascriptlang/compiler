// @stdout: 3 4 5 s7
// @stdout: 3 4 5 s7
function parse(s: string): number;
function parse(s: number): string;
function parse(s: string | number): number | string { return typeof s == "string" ? s.length : `${s}`; }

class Reader {
	read(s: string): number;
	read(s: number): string;
	read(s: string | number): number | string { return typeof s == "string" ? s.length : `s${s}`; }
}

const n: number = parse("abc");
const t: string = parse(4);
const r = new Reader();
const rn: number = r.read("abcd");
const rn2: number = r.read("abcde");
const rt: string = r.read(7);
console.log(n, rn, rn2, rt);
