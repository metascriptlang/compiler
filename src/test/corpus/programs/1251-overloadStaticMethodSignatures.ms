// @stdout: 2 s3 7
class S {
	static mk(a: string): number;
	static mk(a: number): string;
	static mk(a: string | number): number | string { return typeof a == "string" ? a.length : `s${a}`; }
	static wide(a: string): number | string;
	static wide(a: number): number | string;
	static wide(a: string | number): number { return typeof a == "string" ? a.length + 6 : a; }
}
const n: number = S.mk("ab");
const t: string = S.mk(3);
const w: number | string = S.wide("x");
console.log(n, t, w);
