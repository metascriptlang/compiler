import { checkOnly } from "../helpers";

const SRC_KEPT = `
struct Parent { x: int32; }
function parent(): Parent | null { return { x: 3 }; }
function constant(): int32 {
	const under = parent();
	if (under === null) { throw new Error("missing"); }
	const read = (): int32 => under.x;
	return read();
}
function resultScalar(): int32 {
	const value: Result<int32, string> = Result.ok(7);
	if (!value.ok) { return 0; }
	const read = (): int32 => value.value;
	return read();
}
function resultText(): string {
	const value: Result<string, string> = Result.ok("hello");
	if (!value.ok) { return ""; }
	const read = (): string => value.value;
	return read();
}
function param(p: Parent | null): int32 {
	if (p === null) { return 0; }
	const read = (): int32 => p.x;
	return read();
}
function assignedBefore(): int32 {
	let under = parent();
	under = parent();
	if (under === null) { return 0; }
	const read = (): int32 => under.x;
	return read();
}
`;

const SRC_REFUSED = `
struct Parent { x: int32; }
function parent(): Parent | null { return { x: 3 }; }
function clear(ref p: Parent | null): void { p = null; }
function assignedAfter(): int32 {
	let under = parent();
	if (under === null) { return 0; }
	const read = (): int32 => under.x;
	under = null;
	return read();
}
function assignedInClosure(): int32 {
	let under = parent();
	if (under === null) { return 0; }
	const read = (): int32 => under.x;
	const drop = (): void => { under = null; };
	drop();
	return read();
}
function paramAssignedAfter(p: Parent | null): int32 {
	if (p === null) { return 0; }
	const read = (): int32 => p.x;
	p = null;
	return read();
}
function assignedInLoop(): int32 {
	let under = parent();
	let total = 0;
	for (let i = 0; i < 2; i++) {
		under = parent();
		if (under === null) { continue; }
		const read = (): int32 => under.x;
		total += read();
	}
	return total;
}
function refAfter(): int32 {
	let under = parent();
	let read = (): int32 => 0;
	if (under !== null) { read = (): int32 => under.x; }
	clear(under);
	return read();
}
function createdBeforeNarrowing(): int32 {
	const under = parent();
	const read = (): int32 => under.x;
	if (under === null) { return 0; }
	return read();
}
function declaredFunction(): int32 {
	const under = parent();
	if (under === null) { return 0; }
	function read(): int32 { return under.x; }
	return read();
}
`;

test "a closure keeps the narrowing of a binding no later write can change" {
	const errors = checkOnly(SRC_KEPT).errors;
	assert errors.length == 0, "a const, or a param or let assigned only before the closure, must stay narrowed inside it: " + errors.join("\n");
}

test "a closure reads the declared type when a write can follow it" {
	const errors = checkOnly(SRC_REFUSED).errors;
	const refused = errors.filter((e: string): boolean => e.contains("Property 'x' does not exist on type 'Parent | null'"));
	assert refused.length == 7, "each of the seven closures must read 'Parent | null': " + errors.join("\n");
}
