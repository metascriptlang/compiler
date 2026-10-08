// @exit: 1
// @stdout: before center
// @xfail(raiser): the Raiser VM does not test union conversions
// @xfail(danger): --danger drops the membership test, so the string outside the set passes through

type Align = "auto" | "center" | "stretch";

function alignOf(s: string): Align {
	return s as Align;
}

function main(): void {
	const a: string = alignOf("center");
	console.log(`before ${a}`);
	const b: string = alignOf("middle");
	console.log(`after ${b}`);
}
main();
