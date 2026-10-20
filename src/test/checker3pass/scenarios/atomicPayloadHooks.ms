import { checkOnly } from "../helpers";

const MARK = "struct Mark { tag: int32; }\nfunction onDestroy(this m: Mark): void { }\n";

test "an Arc pointee that declares a lifecycle hook is refused, made by new or by a literal" {
	const text = checkOnly(MARK + "const a = new Arc<Mark>({ tag: 1 });\nconst b: Arc<Mark> = { tag: 2 };").errors.join("\n");
	assert text.contains("Arc<T> pointee must not declare a lifecycle hook — 'Mark'");
	assert text.split("Arc<T> pointee must not declare").length == 3;
}

test "a Locked payload that declares a lifecycle hook is refused" {
	const text = checkOnly(MARK + "const l = new Locked<Mark>({ tag: 1 });").errors.join("\n");
	assert text.contains("Locked<T> payload must not declare a lifecycle hook — 'Mark'");
}

test "a payload that holds a hooked value is refused under its own name" {
	const text = checkOnly(MARK + "struct Outer { mark: Mark; n: int32; }\nconst l = new Locked<Outer>({ mark: { tag: 1 }, n: 1 });").errors.join("\n");
	assert text.contains("'Outer' declares one or holds a value that does");
}

test "a Locked payload instantiated from a generic body is refused" {
	const text = checkOnly(MARK + "function boxed<T>(v: T): Locked<T> { return new Locked<T>(v); }\nconst l = boxed<Mark>({ tag: 1 });").errors.join("\n");
	assert text.contains("Locked<T> payload must not declare a lifecycle hook");
}

test "plain payloads without a hook still pass both gates" {
	const result = checkOnly("struct Mark { tag: int32; }\nconst a = new Arc<Mark>({ tag: 1 });\nconst l = new Locked<Mark>({ tag: 2 });");
	assert result.errors.length == 0;
}
