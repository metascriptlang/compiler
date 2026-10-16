import { checkProjectDiagnostics, MapEntry } from "../helpers";

const head = "struct S { x: int32 }\nclass K { x: int32 = 0 }\nenum E { A, B }\nstruct V { n: int32 }\nfunction `<`(a: V, b: V): boolean { return a.n < b.n; }\nfunction mk(): Result<uint64, string> { return Result.ok(5); }\n";

function refused(body: string): int32 {
	const entries: MapEntry[] = [{ entryPath: "src/main.ms", entrySource: head + body }];
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics(entries, "src/main.ms")) {
		if (m.indexOf("cannot be applied to types") >= 0) n += 1;
	}
	return n;
}

function pair(left: string, right: string, op: string): int32 {
	return refused("function f(a: " + left + ", b: " + right + "): boolean { return a " + op + " b; }");
}

test "relationalOperands: every relational operator refuses an operand it cannot order" {
	const ops = ["<", "<=", ">", ">="];
	const others = ["Result<uint64, string>", "S", "K", "string", "int32[]", "Map<string, int32>", "(() => void)", "Ptr<uint64>"];
	for (const op of ops) {
		for (const o of others) {
			assert pair("uint64", o, op) == 1;
			assert pair(o, "uint64", op) == 1;
		}
	}
	assert pair("Result<uint64, string>", "Result<uint64, string>", "<") == 1;
	assert pair("string", "boolean", "<") == 1;
}

test "relationalOperands: ordered pairs and a declared overload are accepted" {
	for (const op of ["<", "<=", ">", ">="]) {
		assert pair("uint64", "uint64", op) == 0;
		assert pair("int32", "float64", op) == 0;
		assert pair("string", "string", op) == 0;
		assert pair("E", "E", op) == 0;
		assert pair("E", "int32", op) == 0;
		assert pair("bigint", "bigint", op) == 0;
		assert pair("Ptr<uint64>", "Ptr<uint64>", op) == 0;
		assert pair("Ptr<uint64>", "Ptr<uint8>", op) == 0;
	}
	assert pair("V", "V", "<") == 0;
}

test "relationalOperands: a pointer orders only against a pointer" {
	for (const op of ["<", "<=", ">", ">="]) {
		assert pair("Ptr<uint64>", "E", op) == 1;
		assert pair("E", "Ptr<uint64>", op) == 1;
		assert pair("Ptr<uint8>", "float64", op) == 1;
		assert pair("int64", "Ptr<uint8>", op) == 1;
	}
}

test "relationalOperands: a union of ordered primitives is accepted on either side" {
	for (const op of ["<", "<=", ">", ">="]) {
		assert pair("int32 | float64", "int32", op) == 0;
		assert pair("uint64", "int32 | float64", op) == 0;
	}
}

test "relationalOperands: a generic instantiated with a Result is refused" {
	assert refused("function lt<T>(a: T, b: T): boolean { return a < b; }\nfunction f(): boolean { return lt(mk(), mk()); }") >= 1;
	assert refused("function lt<T>(a: T, b: T): boolean { return a < b; }\nfunction f(): boolean { return lt(1, 2); }") == 0;
}
