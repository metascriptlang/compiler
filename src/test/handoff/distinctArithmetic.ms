import { checkProjectDiagnostics, MapEntry } from "../helpers";

const head = "type UserId = distinct int32;\ntype Meters = distinct float64;\ntype Tagged<T> = distinct int32;\nstruct S {}\n"
	+ "type Id = int32 & { __brand: \"Id\" };\ntype R = number & { __brand: \"R\" };\n"
	+ "type Sum = distinct int32;\nfunction `+`(a: Sum, b: Sum): Sum { return ((a as int32) + (b as int32)) as Sum; }\n";

function refusals(body: string): int32 {
	const entries: MapEntry[] = [{ entryPath: "src/main.ms", entrySource: head + body }];
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics(entries, "src/main.ms")) {
		if (m.indexOf("cannot be applied to types") >= 0 || m.indexOf("needs a numeric operand") >= 0) n += 1;
	}
	return n;
}

function binary(t: string, op: string): int32 {
	return refusals("function f(a: " + t + ", b: " + t + "): void { const c = a " + op + " b; }");
}

test "distinctArithmetic: a user distinct has no arithmetic of its base" {
	for (const op of ["+", "-", "*", "/", "%"]) {
		assert binary("UserId", op) == 1;
		assert binary("Meters", op) == 1;
		assert binary("Tagged<S>", op) == 1;
	}
	assert refusals("function f(a: UserId): void { const c = a + 1; }") == 1;
	assert refusals("function f(a: UserId): void { const c = -a; }") == 1;
	assert refusals("function f(a: UserId, b: UserId): void { let c = a; c += b; }") == 1;
}

test "distinctArithmetic: a declared operator and a conversion to the base are accepted" {
	assert binary("Sum", "+") == 0;
	assert refusals("function f(a: Sum, b: Sum): void { let c = a; c += b; }") == 0;
	assert refusals("function f(a: UserId, b: UserId): void { const c = (a as int32) + (b as int32); }") == 0;
}

test "distinctArithmetic: a brand computes as its base" {
	for (const op of ["+", "-", "*", "/", "%"]) {
		assert binary("Id", op) == 0;
		assert binary("R", op) == 0;
	}
	assert refusals("function f(a: Id, r: R): int32 { const n: int32 = a + 1; const m: number = r - 0.5 + a; return n & (a << 1); }") == 0;
}
