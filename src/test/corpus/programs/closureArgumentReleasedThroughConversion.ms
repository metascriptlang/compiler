// @stdout: same true false
// @stdout: nullable link none
// @stdout: distinct button
// @stdout: generic 9 2
// note: a function passed where the parameter is wider than the function's own type is released after the call: compared against a binding, behind a nullable parameter, through a distinct cast, and into a generic union of a struct and a function.
type Role = "button" | "link";
type Acc<T> = distinct (() => T);
struct Payload { a: int32; b: int32; }
type Setter<T> = T | ((value: T) => T);

function named(): void {}

function viaParam(m: Acc<Role> | null): string {
	if (m === null) return "none";
	return (m as () => string)();
}

function call(m: Acc<Role>): string {
	return (m as () => string)();
}

function apply<T>(current: T, next: Setter<T>): T {
	if (typeof next === "function") return next(current);
	return next;
}

function widen(value: Payload): Payload { return { a: value.a, b: 9 }; }

function run(): void {
	const zero: () => void = named;
	const other = (): void => {};
	console.log(`same ${zero === named} ${other === named}`);
	console.log(`nullable ${viaParam(((): Role => "link") as Acc<Role>)} ${viaParam(null)}`);
	console.log(`distinct ${call(((): Role => "button") as Acc<Role>)}`);
	const initial: Payload = { a: 1, b: 2 };
	const widened = apply<Payload>(initial, widen);
	const lifted = apply<Payload>(initial, (v: Payload): Payload => ({ a: v.a + 1, b: v.b }));
	console.log(`generic ${widened.b} ${lifted.a}`);
}

run();
