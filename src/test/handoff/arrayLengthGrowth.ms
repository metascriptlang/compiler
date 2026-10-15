import { checkProjectDiagnostics, MapEntry } from "../helpers";

const lib = "export struct Proof { private id: int32; }\nexport function mint(id: int32): Proof { return { id: id }; }\n";
const head = "import { Proof, mint } from \"./lib\";\nclass Holder { n: int32 = 0; }\nstruct Pt { x: int32; y: int32; }\n";

function growthErrors(body: string): int32 {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: lib },
		{ entryPath: "src/main.ms", entrySource: head + body },
	];
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics(entries, "src/main.ms")) {
		if (m.indexOf("'length' cannot be assigned on an array whose elements have no default value") >= 0) n += 1;
	}
	return n;
}

function lengthSet(elem: string, value: string, op: string): int32 {
	return growthErrors("function f(a: " + elem + "[], n: int32): void { a.length " + op + " " + value + "; }");
}

test "arrayLengthGrowth: a length assignment is refused for an element with no default value" {
	assert lengthSet("Proof", "n", "=") == 1;
	assert lengthSet("Holder", "n", "=") == 1;
	assert lengthSet("Map<string, int32>", "n", "=") == 1;
	assert lengthSet("(() => void)", "n", "=") == 1;
	assert lengthSet("Holder[]", "n", "=") == 1;
	assert lengthSet("Proof[]", "n", "=") == 1;
}

test "arrayLengthGrowth: only the literal zero may be assigned" {
	assert lengthSet("Proof", "0", "=") == 0;
	assert lengthSet("Holder", "0", "=") == 0;
	assert lengthSet("Holder", "1", "=") == 1;
	assert lengthSet("Proof", "a.length - 1", "=") == 1;
	assert lengthSet("Holder", "0", "+=") == 1;
	assert lengthSet("Holder", "1", "-=") == 1;
}

test "arrayLengthGrowth: an element with a default value keeps length assignment" {
	assert lengthSet("int32", "n", "=") == 0;
	assert lengthSet("string", "n", "=") == 0;
	assert lengthSet("Pt", "n", "=") == 0;
	assert lengthSet("Holder | null", "n", "=") == 0;
}

test "arrayLengthGrowth: setLength and a generic helper are refused alike at instantiation" {
	assert growthErrors("function f(a: Holder[]): void { a.setLength(3); }") >= 1;
	assert growthErrors("function f(a: Proof[]): void { a.setLength(3); }") >= 1;
	assert growthErrors("function g<T>(a: T[], n: int32): void { a.length = n; }\nfunction f(a: Holder[]): void { g(a, 3); }") >= 1;
	assert growthErrors("function g<T>(a: T[], n: int32): void { a.length = n; }\nfunction f(a: Proof[]): void { g(a, 3); }") >= 1;
	assert growthErrors("function g<T>(a: T[], n: int32): void { a.length = n; }\nfunction f(a: int32[]): void { g(a, 3); }") == 0;
	assert growthErrors("function f(a: int32[]): void { a.setLength(3); }") == 0;
}

test "arrayLengthGrowth: shrink is accepted for every element type" {
	assert growthErrors("function f(a: Proof[], b: Holder[], c: int32[]): void { a.shrink(0); b.shrink(1); c.shrink(2); }") == 0;
	assert growthErrors("function g<T>(a: T[], n: int64): void { a.shrink(n); }\nfunction f(a: Proof[]): void { g(a, 1); }") == 0;
}
