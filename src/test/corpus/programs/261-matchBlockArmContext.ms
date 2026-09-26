enum Failure {
	Rejected,
	TooBig,
}

class Box {
	n: uint64 = 0;
}

function failureName(failure: Failure): string {
	return match (failure) {
		Failure.Rejected => "Rejected",
		Failure.TooBig => "TooBig",
	};
}

function show(r: Result<uint64, Failure>): string {
	if (r.ok) { return `ok ${r.value}`; }
	return `err ${failureName(r.error)}`;
}

function okInBlockArm(value: uint32): Result<uint64, Failure> {
	return match (value) {
		0 => {
			const result: uint64 = 7;
			return Result.ok(result);
		},
		_ => Result.err(Failure.Rejected),
	};
}

function errInBlockArm(value: uint32): Result<uint64, Failure> {
	return match (value) {
		0 => Result.ok(5),
		_ => {
			const failure = Failure.TooBig;
			return Result.err(failure);
		},
	};
}

function returnNestedInArm(value: uint32): Result<uint64, Failure> {
	return match (value) {
		0 => Result.err(Failure.Rejected),
		_ => {
			if (value > 10) {
				return Result.err(Failure.TooBig);
			}
			const doubled: uint64 = value * 2;
			return Result.ok(doubled);
		},
	};
}

function matchInsideArm(value: uint32, flag: boolean): Result<uint64, Failure> {
	const outer: Result<uint64, Failure> = match (value) {
		0 => {
			const inner: Result<uint64, Failure> = match (flag) {
				true => {
					return Result.ok(1);
				},
				false => Result.err(Failure.Rejected),
			};
			return inner;
		},
		_ => {
			return Result.ok(9);
		},
	};
	return outer;
}

function statementMatch(value: uint32): Result<uint64, Failure> {
	match (value) {
		0 => {
			return Result.ok(3);
		},
		_ => {
			console.log("statement arm falls through");
		},
	};
	return Result.err(Failure.Rejected);
}

function nullInArm(value: uint32): uint64 {
	const box: Box | null = match (value) {
		0 => {
			return null;
		},
		_ => new Box(),
	};
	return box == null ? 0 : 1;
}

function lambdaInArm(value: uint32): string {
	return match (value) {
		0 => {
			const next = (n: uint64): uint64 => { return n + 1; };
			return `next ${next(41)}`;
		},
		_ => "other",
	};
}

console.log(show(okInBlockArm(0)), show(okInBlockArm(1)));
console.log(show(errInBlockArm(0)), show(errInBlockArm(1)));
console.log(show(returnNestedInArm(0)), show(returnNestedInArm(4)), show(returnNestedInArm(11)));
console.log(show(matchInsideArm(0, true)), show(matchInsideArm(0, false)), show(matchInsideArm(3, true)));
console.log(show(statementMatch(0)), show(statementMatch(1)));
console.log(nullInArm(0), nullInArm(1));
console.log(lambdaInArm(0), lambdaInArm(1));
