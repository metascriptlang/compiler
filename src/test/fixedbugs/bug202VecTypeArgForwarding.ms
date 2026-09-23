// Symptom: JSON.stringify of a top-level Vec<struct> failed instantiation: "got Array, expected F[]".
// Root cause: monoConcreteTypeName spelled a value array as "Array<F>", which re-resolves to the Ref'd F[].
// Fix: a value array spells "Vec<F>"; only a plain Ref to an array spells "Array<F>".

struct B202File { path: string; }

function b202Inner<T>(v: T): number { return 1; }
function b202Outer<T>(v: T): number { return b202Inner<T>(v); }

test "bug202: JSON.stringify of a Vec<struct>" {
	const files: Vec<B202File> = [{ path: "a" }];
	assert JSON.stringify(files) == `[{"path":"a"}]`;
}

test "bug202: a Vec<number> type arg forwards through a generic" {
	const nums: Vec<number> = [1, 2];
	assert b202Outer(nums) == 1;
}

test "bug202: an F[] type arg still forwards as F[]" {
	const files: B202File[] = [{ path: "b" }];
	assert b202Outer(files) == 1;
	assert JSON.stringify(files) == `[{"path":"b"}]`;
}
