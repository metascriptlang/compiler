// Every arrow here returns a value on purpose: a failing assert must leave through the
// raise path, because a bare `return;` is ill-formed C in a non-void function.

function runGeneric<T>(fn: (d: () => void) => T): T {
	const d = (): void => {};
	return fn(d);
}

test "1: assert inside a concretely-typed non-void arrow" {
	const double = (v: number): number => {
		assert v > 0, "positive";
		return v * 2;
	};
	assert double(3) == 6, "doubled";
}

test "2: assert inside a void arrow still works" {
	let seen = 0;
	const bump = (v: number): void => {
		assert v > 0, "positive";
		seen = (seen + v) as int32;
	};
	bump(3);
	assert seen == 3, "ran";
}

test "3: assert directly in the test body still works" {
	const x = 1 + 1;
	assert x == 2, "x is 2";
}

test "4: assert inside a generic callback whose type param is unresolved" {
	runGeneric((d) => {
		const x = 1 + 1;
		assert x == 2, "x is 2";
		d();
	});
}

test "5: assert inside an arrow returning a string" {
	const label = (v: number): string => {
		assert v >= 0, "non-negative";
		return v.toString();
	};
	assert label(7) == "7", "stringified";
}

test "6: assert nested two arrows deep in a non-void chain" {
	const outer = (v: number): number => {
		const inner = (w: number): number => {
			assert w > 0, "inner positive";
			return w + 1;
		};
		assert v > 0, "outer positive";
		return inner(v) * 2;
	};
	assert outer(2) == 6, "nested";
}
