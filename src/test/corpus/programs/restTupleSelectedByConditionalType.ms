// @stdout: Home|Detail|Detail:b:x
// @stdout: opt:a:none|opt:b:2|first:p:1|pair:q:2
// note: a rest parameter typed by a tuple takes the tuple's elements as arguments; a conditional
// type over the inferred type parameter picks the tuple, and a missing optional element is null.
interface ParamList {
	Home: null;
	Detail: { id: string; tab: string | null };
}

type Args<K extends keyof ParamList> = null extends ParamList[K]
	? [name: K, params?: ParamList[K]]
	: [name: K, params: ParamList[K]];

function go<K extends keyof ParamList>(...args: Args<K>): string {
	return args[0];
}

function detail(...args: [name: "Detail", params: { id: string; tab: string | null }]): string {
	const p = args[1];
	return args[0] + ":" + p.id + ":" + (p.tab == null ? "none" : p.tab);
}

function opt(...args: [name: string, n?: int32]): string {
	const n = args[1];
	return "opt:" + args[0] + ":" + (n == null ? "none" : String(n));
}

function first<P extends [string, int32]>(...args: P): string {
	return "first:" + args[0] + ":" + String(args[1]);
}

type Pair<T> = [T, int32];

function pair<T>(...args: Pair<T>): string {
	return "pair:" + String(args[0]) + ":" + String(args[1]);
}

console.log([go("Home"), go("Detail", { id: "a", tab: null }), detail("Detail", { id: "b", tab: "x" })].join("|"));
console.log([opt("a"), opt("b", 2), first("p", 1), pair("q", 2)].join("|"));
