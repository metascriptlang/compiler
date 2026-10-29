// @stdout: fn override {"fontSize":13,"onKey":null}
// @stdout: number override {"fontSize":null,"name":"haro"}
// @stdout: two spreads {"fontSize":13,"name":"x","onKey":null}
// @stdout: plain null {"a":1,"b":null}
// @stdout: kept handler true
// note: `undefined` is an alias of `null`, so a field a spread overrides with it is typed `null` and is written as `null`.
interface Config {
	fontSize?: number;
	name?: string;
	onKey?: (code: string) => boolean;
}

const base: Config = {
	fontSize: 13,
	name: "haro",
	onKey: (code: string): boolean => code == "K",
};

const noHandler: Config = { fontSize: 13 };

console.log("fn override " + JSON.stringify({ ...noHandler, onKey: undefined }));

interface Plain {
	fontSize?: number;
	name?: string;
}
const bare: Plain = { name: "haro" };
console.log("number override " + JSON.stringify({ ...bare, fontSize: undefined }));

const mid = { ...noHandler, onKey: undefined };
console.log("two spreads " + JSON.stringify({ ...mid, name: "x" }));

console.log("plain null " + JSON.stringify({ a: 1, b: null }));

const kept = { ...base, name: "other" };
const handler = kept.onKey;
console.log("kept handler " + (handler != null && handler("K")));
