// @exit: 1
// @stdout: before center 4
// @skip-js: node exits 1 with the same "member 'string' is not accessible" line but wraps it in its own uncaught-error report, and parity compares merged stdout+stderr (sibling of 647)
// @xfail(raiser): the Raiser VM does not test union conversions
// @xfail(danger): --danger drops the nullable union's tag test like every field check, so the read of the other member is undefined behaviour

type Align = "auto" | "center" | "stretch";
type Wire = number | string | null;

function alignOf(v: Wire): Align | null {
	return v as Align | null;
}

function numberOf(v: Wire): number | null {
	return v as number | null;
}

function show(a: Align | null): string {
	if (a == null) return "null";
	const t: string = a;
	return t;
}

function main(): void {
	const text: Wire = "center";
	const four: Wire = 4;
	const n = numberOf(four);
	console.log(`before ${show(alignOf(text))} ${n == null ? "null" : `${n}`}`);
	console.log(`after ${show(alignOf(four))}`);
}
main();
