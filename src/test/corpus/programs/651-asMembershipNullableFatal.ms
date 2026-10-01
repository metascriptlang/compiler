// @exit: 1
// @stdout: before center null
// @skip-js: node exits 1 with the same "invalid union conversion: \"middle\" is not Align" line but wraps it in its own uncaught-error report, and parity compares merged stdout+stderr (sibling of 647)
// @xfail(raiser): the Raiser VM does not test union conversions
// @xfail(danger): --danger drops the membership test, so the string outside the set passes through

type Align = "auto" | "center" | "stretch";
type Wire = number | string | null;

function alignOf(v: Wire): Align | null {
	return v as Align | null;
}

function show(a: Align | null): string {
	if (a == null) return "null";
	const t: string = a;
	return t;
}

function main(): void {
	const good: Wire = "center";
	const none: Wire = null;
	const bad: Wire = "middle";
	console.log(`before ${show(alignOf(good))} ${show(alignOf(none))}`);
	console.log(`after ${show(alignOf(bad))}`);
}
main();
