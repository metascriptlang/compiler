// bug099 — variant value into a union slot skipped the widening conversion
//
// Symptom:    `const s: Shape = c` / `return c` / `Result.ok(c)` with
//             c: Circle and Shape = Circle | Square emitted a raw C assign
//             (`assigning to 'Shape' from 'Circle *'`); a plain call arg
//             passed the bare variant pointer with only a clang warning
//             (silent layout pun at runtime).
// Root cause: the variant→union HiddenSubConv existed but was injected only
//             on the overload sig→impl reconcile path; fitNode, the
//             direct-call arg loop and inferGenericReturn never wrapped, so
//             every other fit position handed codegen an unconverted variant.
// Fix:        widenVariantToUnion injected at fitNode + the call-arg loop +
//             inferGenericReturn after bindings settle (checkExprPass.ms);
//             the conv emitter derefs pointer-repr payloads (expressions.ms).

interface B99Circle { kind: "circle"; r: float64; }
interface B99Square { kind: "square"; s: float64; }
type B99Shape = B99Circle | B99Square;

function b99take(sh: B99Shape): float64 {
	if (sh.kind === "circle") {
		return sh.r;
	}
	return sh.s;
}

function b99pick(which: boolean): B99Shape {
	if (which) {
		const c: B99Circle = { kind: "circle", r: 1.5 };
		return c;
	}
	const q: B99Square = { kind: "square", s: 2.5 };
	return q;
}

function b99res(which: boolean): Result<B99Shape, string> {
	if (which) {
		const c: B99Circle = { kind: "circle", r: 4.5 };
		return Result.ok(c);
	}
	return Result.err("nope");
}

test "bug099: variant widens at var init" {
	const c: B99Circle = { kind: "circle", r: 3.0 };
	const a: B99Shape = c;
	assert a.kind === "circle";
	assert b99take(a) === 3.0;
}

test "bug099: variant widens at reassignment" {
	const c: B99Circle = { kind: "circle", r: 5.0 };
	let b: B99Shape = { kind: "square", s: 2.0 };
	assert b.kind === "square";
	b = c;
	assert b.kind === "circle";
	assert b99take(b) === 5.0;
}

test "bug099: variant widens at a plain call argument" {
	const c: B99Circle = { kind: "circle", r: 6.0 };
	assert b99take(c) === 6.0;
}

test "bug099: variant widens on return" {
	const s = b99pick(true);
	assert s.kind === "circle";
	const q = b99pick(false);
	assert q.kind === "square";
}

test "bug099: variant widens through Result.ok generic inference" {
	const r = b99res(true);
	assert r.ok;
	if (r.ok) {
		assert r.value.kind === "circle";
	}
}

test "bug099: source stays readable after a copying widen" {
	const c: B99Circle = { kind: "circle", r: 9.0 };
	const s: B99Shape = c;
	assert c.r === 9.0;
	assert b99take(s) === 9.0;
}
