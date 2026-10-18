// @stdout: calls=9 texts=9
// note: a value converted to text is evaluated exactly once, in a template, in String(x) and in a string concatenation: a distinct number or string through its declared toString, and a Map, whose text is a placeholder that differs by backend and is not printed here.

type Small = distinct int8;
type Name = distinct string;
function toString(this x: Small): string { return "S" + (x as int8).toString(); }
function toString(this x: Name): string { return x as string; }

let calls = 0;
const shared = new Map<string, int32>();
function mkS(): Small { calls++; return 5 as Small; }
function mkN(): Name { calls++; return "ann" as Name; }
function mkM(): Map<string, int32> { calls++; return shared; }

function main(): void {
	const texts: string[] = [];
	texts.push(`${mkS()}`);
	texts.push(String(mkS()));
	texts.push("" + mkS());
	texts.push(`${mkN()}`);
	texts.push(String(mkN()));
	texts.push("" + mkN());
	texts.push(`${mkM()}`);
	texts.push(String(mkM()));
	texts.push("" + mkM());
	console.log(`calls=${calls} texts=${texts.length}`);
}

main();
