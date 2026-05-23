// Stress: combined scenario — generic constructor + generic method call
// + generic function chain + closure args + explicit type args. Real-world
// integration shape that touches MULTIPLE Phase C/D entry points in one
// program.

import { TypeKind } from "../../../ast/node";
import { checkOnly } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_MIXED = `
class Pipeline<T> {
	value: T;
	constructor(initial: T) {
		this.value = initial;
	}
	map<U>(f: (x: T) => U): U {
		return f(this.value);
	}
}

function compose<A, B, C>(f: (x: A) => B, g: (y: B) => C): (z: A) => C {
	return (z: A) => g(f(z));
}

function mainMixed(): void {
	const factor: int32 = 4 as int32;
	const inc = (x: int32) => (x + factor) as int32;
	const dbl = (y: int32) => (y * (2 as int32)) as int32;
	const both = compose<int32, int32, int32>(inc, dbl);

	const p = new Pipeline<int32>(5 as int32);
	const r = p.map<int32>((x) => (x * factor) as int32);
}
`;

test "stress mixed: no checker errors" {
	const result = checkOnly(SRC_MIXED);
	if (result.errors.length > 0) {
		console.log("[stress mixed errors]");
		for (const e of result.errors) { console.log("  - " + e); }
	}
	assert result.errors.length === 0;
}

test "stress mixed: no GenericParam leakage across constructor + method + compose chain" {
	const result = checkOnly(SRC_MIXED);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
