// @stdout: Home:none|Detail:a|Home:none|Detail:b
// @stdout: w:x:none|w:x:2|d:y:none|d:y:3
// @stdout: m:p:none|m:p:q|s:r:none|s:r:4|f:1:t:none|f:1:t:5
// @stdout: o:a:none|o:a:some|nav:Home:none|nav:Detail:c
// note: an omitted optional element of a rest tuple reads null on every backend, whether the tuple
// is written or selected by a conditional type, through a free function or a method.
type Params = { Home: undefined; Detail: { id: string } };
type Args<K extends keyof Params> = Params[K] extends undefined ? [name: K, params?: Params[K]] : [name: K, params: Params[K]];

function go<K extends keyof Params>(...args: Args<K>): string {
	const p = args[1];
	return args[0] + ":" + (p == null ? "none" : (p as { id: string }).id);
}

function goPair<K extends keyof Params>(...args: Args<K>): string {
	const [n, p] = args;
	return n + ":" + (p == null ? "none" : (p as { id: string }).id);
}

function w(...args: [a: string, b?: number]): string {
	return "w:" + args[0] + ":" + (args[1] == null ? "none" : String(args[1]));
}

function d(...args: [a: string, b?: number | null]): string {
	const [n, p] = args;
	return "d:" + n + ":" + (p === undefined || p === null ? "none" : String(p));
}

function o(...args: [a: string, b?: { id: string }]): string {
	return "o:" + args[0] + ":" + (args[1] == null ? "none" : "some");
}

class Router {
	m(...args: [a: string, b?: string]): string {
		return "m:" + args[0] + ":" + (args[1] == null ? "none" : args[1]);
	}
	static s(...args: [a: string, b?: int32]): string {
		const [n, p] = args;
		return "s:" + n + ":" + (p == null ? "none" : String(p));
	}
	f(head: int32, ...args: [a: string, b?: int32]): string {
		return "f:" + String(head) + ":" + args[0] + ":" + (args[1] == null ? "none" : String(args[1]));
	}
	nav<K extends keyof Params>(...args: Args<K>): string {
		const p = args[1];
		return "nav:" + args[0] + ":" + (p == null ? "none" : (p as { id: string }).id);
	}
}

const r = new Router();
console.log([go("Home"), go("Detail", { id: "a" }), goPair("Home"), goPair("Detail", { id: "b" })].join("|"));
console.log([w("x"), w("x", 2), d("y"), d("y", 3)].join("|"));
console.log([r.m("p"), r.m("p", "q"), Router.s("r"), Router.s("r", 4), r.f(1, "t"), r.f(1, "t", 5)].join("|"));
console.log([o("a"), o("a", { id: "z" }), r.nav("Home"), r.nav("Detail", { id: "c" })].join("|"));
