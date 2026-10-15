// @stdout: calls=3
// @skip-raiser: the raiser prints the value of a distinct and `[object]` for a Map where C and JS print the type name; stringifyEvaluatesOperand.ms pins the raiser's evaluation
// note: console.log evaluates its argument exactly once, also when the argument's type has no text of its own and prints a placeholder (a distinct number, a distinct string, a Map).

type Small = distinct int8;
type Name = distinct string;

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
