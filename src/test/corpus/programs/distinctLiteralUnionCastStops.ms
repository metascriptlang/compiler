// @exit: 1
// @stdout: in a
// @stdout: invalid union conversion: "c" is not Narrow
// @xfail(danger): --danger drops the conversion check, so the distinct holds a value outside Narrow instead of stopping
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
