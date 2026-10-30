// @stdout: 3 n 5 n s7 true 2
function pick(s: string): number | string;
function pick(s: number): number | string;
function pick(s: string | number): number { return typeof s == "string" ? s.length : s + 1; }

function widen(s: string): number | string | boolean;
function widen(s: number): number | string | boolean;
function widen(s: string | number): number | string { return typeof s == "string" ? s : s; }

class Reader {
	read(s: string): number | string;
	read(s: number): number | string;
	read(s: string | number): number { return typeof s == "string" ? s.length : s + 1; }
}

function kind(v: number | string): string { return typeof v == "number" ? "n" : "s"; }
const a: number | string = pick("abc");
const r = new Reader();
const b: number | string = r.read(4);
const c: number | string | boolean = widen("s7");
console.log(a, kind(a), b, kind(b), c, c == "s7" ? "true" : "false", 2);
