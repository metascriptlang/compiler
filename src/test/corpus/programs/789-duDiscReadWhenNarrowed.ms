// Parity program — reading the discriminant of an enum-discriminated union
// through a reference the flow graph already narrowed to one variant: inside
// the positive block, inside the block of a negative test, and after a
// narrowing the whole rest of the scope carries.
//
// @stdout: in 0 1|neg 0|rest 1 0|key 1
// @exit: 0

enum EvKind { Click, KeyPress }

type Event = match (kind: EvKind) {
	EvKind.Click => { x: int32, y: int32 },
	EvKind.KeyPress => { code: string },
};

function click(): Event { return { kind: EvKind.Click, x: 1, y: 2 }; }
function key(): Event { return { kind: EvKind.KeyPress, code: "Esc" }; }

function insideBlock(e: Event): string {
	if (e.kind == EvKind.Click) { return `in ${e.kind as int32} ${e.x}`; }
	return "no";
}

function negativeBlock(e: Event): string {
	if (e.kind != EvKind.KeyPress) { return `neg ${e.kind as int32}`; }
	return "no";
}

function restOfScope(e: Event): string {
	if (e.kind != EvKind.Click) { return "no"; }
	const x = e.x;
	return `rest ${x} ${e.kind as int32}`;
}

function otherVariant(e: Event): string {
	if (e.kind == EvKind.KeyPress) { return `key ${e.kind as int32}`; }
	return "no";
}

function main(): void {
	const c = click();
	console.log(`${insideBlock(c)}|${negativeBlock(c)}|${restOfScope(c)}|${otherVariant(key())}`);
}

main();
