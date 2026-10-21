// @stdout: early 3
// @stdout: then 3
// @stdout: result 7 hello 9
// @stdout: param 4
// @stdout: let 5
// @stdout: nested 6
// note: a closure created after a narrowing reads the captured binding at the narrowed type when no write can follow: a const, or a parameter or let whose every assignment comes before the closure and sits in no nested function. Before, every closure body started from the declared type, so a field of a narrowed nullable struct or the payload of a narrowed Result was refused inside the closure on every backend.
struct Parent { x: int32; }
interface TextureLike { view: uint32; }
function parent(x: int32): Parent | null { return x < 0 ? null : { x: x }; }
function mount(body: () => int32): int32 { return body(); }
function early(): int32 {
	const under = parent(3);
	if (under === null) { throw new Error("missing parent"); }
	return mount((): int32 => under.x);
}
function then(): int32 {
	const under = parent(3);
	if (under !== null) {
		const read = (): int32 => under.x;
		return read();
	}
	return -1;
}
function texture(): Result<TextureLike, string> { return Result.ok({ view: 9 }); }
function result(): string {
	const scalar: Result<int32, string> = Result.ok(7);
	const text: Result<string, string> = Result.ok("hello");
	const tex = texture();
	if (!scalar.ok || !text.ok || !tex.ok) { return "failed"; }
	const read = (): string => `${scalar.value} ${text.value} ${tex.value.view}`;
	return read();
}
function param(p: Parent | null): int32 {
	if (p === null) { return -1; }
	return mount((): int32 => p.x);
}
function local(): int32 {
	let under = parent(-1);
	under = parent(5);
	if (under === null) { return -1; }
	return mount((): int32 => under.x);
}
function nested(): int32 {
	const under = parent(6);
	if (under === null) { return -1; }
	return mount((): int32 => mount((): int32 => under.x));
}
console.log("early", early());
console.log("then", then());
console.log("result", result());
console.log("param", param(parent(4)));
console.log("let", local());
console.log("nested", nested());
