// @stdout: Search:b2 Search:- Item:i1 | Search:e5 | d4
interface SearchParams { query: string; page: int32; }
interface Lists { Search: SearchParams | null; Item: SearchParams; }
function go<K extends keyof Lists>(...args: null extends Lists[K] ? [name: K, params?: SearchParams | null] : [name: K, params: SearchParams]): string {
	const p = args[1];
	return p == null ? String(args[0]) + ":-" : String(args[0]) + ":" + p.query + p.page;
}
function bare<K extends keyof Lists>(...args: null extends Lists[K] ? [name: K, params?: SearchParams] : [name: K, params: SearchParams]): string {
	const p = args[1];
	return p == null ? String(args[0]) + ":-" : String(args[0]) + ":" + p.query + p.page;
}
class Nav<K extends keyof Lists> {
	to(...args: null extends Lists[K] ? [name: K, params?: SearchParams | null] : [name: K, params: SearchParams]): string {
		const p = args[1];
		return p == null ? "-" : p.query + p.page;
	}
}
console.log(go("Search", { query: "b", page: 2 }), go("Search"), go("Item", { query: "i", page: 1 }), "|", bare("Search", { query: "e", page: 5 }), "|", new Nav<"Search">().to("Search", { query: "d", page: 4 }));
