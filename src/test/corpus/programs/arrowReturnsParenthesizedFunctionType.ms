// @stdout: 3 13 22 21 7 5 yes

const make = (n: int32): ((x: int32) => int32) => (x: int32): int32 => x + n;
const makeUntyped = (n: int32): (() => int32) => {
	return () => n * 2;
};
const unionParam = (flag: boolean): ((v: int32 | string) => string) => (v: int32 | string): string => flag ? "yes" : "no";

class Adder {
	curry = (n: int32): ((x: int32) => int32) => (x: int32): int32 => x + n + 10;
}

const makeAsync = async (n: int32): Promise<(x: int32) => int32> => (x: int32): int32 => x * n;

function twice(f: (x: int32) => int32): (x: int32) => int32 {
	return (x: int32): int32 => f(f(x));
}

async function main(): Promise<void> {
	const add = await makeAsync(3);
	const parts: string[] = [];
	parts.push(make(1)(2).toString());
	parts.push(new Adder().curry(1)(2).toString());
	parts.push(twice(make(10))(2).toString());
	parts.push(add(7).toString());
	parts.push(make(3)(4).toString());
	parts.push(makeUntyped(2)().toString() === "4" ? "5" : "0");
	parts.push(unionParam(true)(1));
	console.log(parts.join(" "));
}

main();
