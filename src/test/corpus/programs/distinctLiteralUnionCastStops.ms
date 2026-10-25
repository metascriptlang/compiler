// @exit: 1
// @stdout: in a
// @stdout: invalid union conversion: "c" is not Narrow
// @xfail(danger): --danger drops the conversion check, so the distinct holds a value outside Narrow instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid union conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output
// note: a cast into a distinct of a literal union is checked through its base, as the cast into a distinct of a class is.

type Wide = "a" | "b" | "c";
type Narrow = "a" | "b";
type Pos = distinct Narrow;

function read(x: Wide): Wide { return x; }
function toPos(x: Wide): Pos { return x as Pos; }

function main(): void {
	console.log("in", toPos(read("a")) as Narrow);
	console.log("out", toPos(read("c")) as Narrow);
	console.log("unreachable");
}

main();
