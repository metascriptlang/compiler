import { compileToCWithStd } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";

struct CallableFit {
	formal: string;
	actual: string;
	accepted: boolean;
}

test "callable slots require compatible parameter and return representations" {
	const cases: CallableFit[] = [
		{ formal: "() => int32", actual: "mkInt(7)", accepted: true },
		{ formal: "() => number", actual: "mkInt(7)", accepted: false },
		{ formal: "() => string", actual: "mkNumber(7)", accepted: false },
		{ formal: "string", actual: "mkNumber(7)", accepted: false },
		{ formal: "() => number", actual: "mkNumber(7)", accepted: true },
	];
	for (const c of cases) {
		const result = compileToCWithStd(`
function mkInt(v: int32): () => int32 { let val = v; return (): int32 => val; }
function mkNumber(v: number): () => number { let val = v; return (): number => val; }
function consume(f: ${c.formal}): void { }
consume(${c.actual});
`);
		assert result.ok == c.accepted, c.actual + " into " + c.formal;
	}
}

test "generic distinct formals bind only their own nominal constructor" {
	for (const argument of ["5", "5 as Other<int32>", "5 as Wrap<int32>"]) {
		const result = compileToCWithStd(`
type Wrap<T> = distinct T;
type Other<T> = distinct T;
function peel<T>(w: Wrap<T>): T { return w as T; }
console.log(peel(${argument}));
`);
		assert result.ok == (argument == "5 as Wrap<int32>"), argument;
	}
}

test "async arrow syntax accepts annotations but its callable result must be a Promise" {
	for (const annotation of ["", ": int32", ": Promise<int32>"]) {
		const source = `async function run(): Promise<int32> { const f = async ()${annotation} => 42; return await f(); } run();`;
		if (annotation == ": int32") assert parseSource(source).ok, annotation + " syntax";
		const result = compileToCWithStd(source);
		assert result.ok == (annotation != ": int32"), annotation + " return representation";
	}
}
