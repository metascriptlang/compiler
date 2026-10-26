// @exit: 1
// @stdout: before center
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
