// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: 2 s7 s7 3 s4
// note: an overload signature's return types the awaited value of an actor call or an async function, the future itself stays a future.
actor Maker {
	mk(a: string): number;
	mk(a: number): string;
	mk(a: string | number): number | string { return typeof a == "string" ? a.length : `s${a}`; }
	wide(a: string): number | string | boolean;
	wide(a: number): number | string | boolean;
	wide(a: string | number): number | string { return typeof a == "string" ? a.length : `s${a}`; }
}

async function conv(a: string): Promise<number>;
async function conv(a: number): Promise<string>;
async function conv(a: string | number): Promise<number | string> { return typeof a == "string" ? a.length : `s${a}`; }

async function main(): Promise<void> {
	const o = new Maker();
	const n: number = await o.mk("ab");
	const s: string = await o.mk(7);
	const w: number | string | boolean = await o.wide(7);
	const cn: number = await conv("abc");
	const cs: string = await conv(4);
	console.log(n, s, w, cn, cs);
}
main();
