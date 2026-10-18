// @stdout: calls=3
// @skip-raiser: the raiser prints `[object]` for a Map where C and JS print the type name; stringifyEvaluatesOperand.ms pins the raiser's evaluation
// note: console.log evaluates its argument exactly once: a distinct number or string through its declared toString, and a Map, whose text is a placeholder.

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
	console.log(mkS());
	console.log(mkN());
	console.log(mkM());
	console.log(`calls=${calls}`);
}

main();
