// @stdout: x 1 s y 4 3 abc
type Fn = (a: int32, b: string) => string;
type Done = Awaited<Promise<int32> | string>;

function call(f: Fn): ReturnType<Fn> {
	return f(1, "s");
}
function swap(p: Parameters<Fn>): Parameters<Fn> {
	return p;
}
async function load(): Promise<string> {
	return "abc";
}
async function main(): Promise<void> {
	const got: Awaited<Promise<string>> = await load();
	const p = swap([1, "s"]);
	const d: Done = "y";
	const e: Done = 4;
	const n: Awaited<ReturnType<() => int32>> = 3;
	console.log(call((a: int32, b: string): string => "x"), p[0], p[1], d, e, n, got);
}
main();
