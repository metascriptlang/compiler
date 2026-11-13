// @stdout: 1 2
// @stdout: instance 1
// note: a fresh array literal passed as `Span<Step>` or `Readonly<Span<Step>>` holds `Step` elements, as under a `Step[]` context, and a read-only span reads a narrower literal array as its union. Covered: one and two elements into a read-only span, a writable span written by the callee, a `"vertex"[]` variable read through `Readonly<Span<Step>>`.
type Step = "vertex" | "instance";

function count(steps: Readonly<Span<Step>>): int32 {
	return steps.length as int32;
}

function first(steps: Span<Step>): Step {
	steps[0] = "instance";
	return steps[0];
}

console.log(count(["vertex"]), count(["vertex", "instance"]));
const only: "vertex"[] = ["vertex"];
console.log(first(["vertex"]), count(only));
