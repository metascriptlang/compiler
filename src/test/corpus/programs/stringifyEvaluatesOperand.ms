// @stdout: calls=9 texts=9
// note: a value converted to text is evaluated exactly once, also when its type has no text of its own and prints a placeholder (a distinct number, a distinct string, a Map): in a template, in String(x) and in a string concatenation. The texts themselves differ by backend and are not printed here.

type Small = distinct int8;
type Name = distinct string;

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
