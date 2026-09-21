// Parity program — narrowing a boolean-discriminated union by comparing the
// discriminant to a boolean literal, the spelling `if (r.ok)` already covered:
// `== true`, `== false`, `!= true` and the same on a user-declared union.
//
// @stdout: ok 5|err division by zero|neg division by zero|user hi
// @exit: 0

type DivResult = Result<number, string>;

type Step =
	| { done: true, label: string }
	| { done: false, retry: int32 };

function divide(a: number, b: number): DivResult {
	if (b == 0) return Result.err("division by zero");
	return Result.ok(a / b);
}

function okBranch(): string {
	const r = divide(10, 2);
	if (r.ok == true) return `ok ${r.value}`;
	return "no";
}

function errBranch(): string {
	const r = divide(10, 0);
	if (r.ok == false) return `err ${r.error}`;
	return "no";
}

function negated(): string {
	const r = divide(10, 0);
	if (r.ok != true) return `neg ${r.error}`;
	return "no";
}

function userUnion(): string {
	const s: Step = { done: true, label: "hi" };
	if (s.done == true) return `user ${s.label}`;
	return "no";
}

function main(): void {
	console.log(`${okBranch()}|${errBranch()}|${negated()}|${userUnion()}`);
}

main();
