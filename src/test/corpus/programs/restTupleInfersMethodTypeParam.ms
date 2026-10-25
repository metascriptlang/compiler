// @stdout: fn:Home|fn:Detail|nav:Home|nav:Detail
// @stdout: generic:Home|generic:Detail|static:Detail|link:Detail>Home|link:Home>Detail
// note: a method infers its own type parameter from a rest parameter whose tuple a conditional
// type selects, as a free function does: on a plain class, a generic class, a static method and
// with two type parameters.
interface ParamList {
	Home: null;
	Detail: { id: string; tab: string | null };
}

type Args<PL, K extends keyof PL> = null extends PL[K] ? [name: K, params?: PL[K]] : [name: K, params: PL[K]];

function go<K extends keyof ParamList>(...args: Args<ParamList, K>): string {
	return "fn:" + args[0];
}

class Nav {
	navigate<K extends keyof ParamList>(...args: null extends ParamList[K] ? [name: K, params?: ParamList[K]] : [name: K, params: ParamList[K]]): string {
		return "nav:" + args[0];
	}

	static open<K extends keyof ParamList>(...args: Args<ParamList, K>): string {
		return "static:" + args[0];
	}

	link<A extends keyof ParamList, B extends keyof ParamList>(...args: null extends ParamList[B] ? [from: A, to: B] : [from: A, to: B, params: ParamList[B]]): string {
		return "link:" + args[0] + ">" + args[1];
	}
}

class Typed<PL> {
	navigate<K extends keyof PL>(...args: Args<PL, K>): string {
		return "generic:" + (args[0] as string);
	}
}

const nav = new Nav();
const typed = new Typed<ParamList>();
console.log([go("Home"), go("Detail", { id: "a", tab: null }), nav.navigate("Home"), nav.navigate("Detail", { id: "b", tab: "x" })].join("|"));
console.log([typed.navigate("Home"), typed.navigate("Detail", { id: "c", tab: null }), Nav.open("Detail", { id: "d", tab: null }),
	nav.link("Detail", "Home"), nav.link("Home", "Detail", { id: "e", tab: null })].join("|"));
