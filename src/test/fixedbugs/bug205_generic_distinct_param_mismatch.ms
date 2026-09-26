// Symptom: after bug204, a value that cannot bind a generic distinct formal (`peel(5)`) reported only "cannot instantiate: 'T' — annotate the destination type", pointing at the wrong fix.
// Root cause: the deferred argument reached `inferGenericReturn`'s unbound-formal check, which assumed a missing annotation.
// Fix: an argument not assignable to its unbound formal reports the argument mismatch at the argument, as Nim's first type mismatch does.
import { compileToCWithStd } from "../helpers";

function peelError205(arg: string): string {
	const result = compileToCWithStd(`
type Wrap<T> = distinct T;
type Other<T> = distinct T;
function peel<T>(w: Wrap<T>): T { return w as T; }
function main(): int32 { console.log(peel(${arg})); return 0; }
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug205: a plain value into a generic distinct formal reports the argument mismatch" {
	const error = peelError205("5");
	assert error.indexOf("Argument type mismatch in 'peel' arg 0: got int32, expected Wrap<T>", 0) >= 0, error;
	assert error.indexOf("cannot instantiate", 0) < 0, error;
}

test "bug205: another distinct into a generic distinct formal reports the argument mismatch" {
	const error = peelError205("5 as Other<int32>");
	assert error.indexOf("Argument type mismatch in 'peel' arg 0: got Other<int32>, expected Wrap<T>", 0) >= 0, error;
	assert error.indexOf("cannot instantiate", 0) < 0, error;
}
