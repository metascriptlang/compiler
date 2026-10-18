// @stdout: foo bar foo bar foo
// note: an argument into a generic union formal that still names a type parameter (`T | Foo`, `Foo | T`) is converted against the instance's union, not the open one, so the instance reads the member that was passed. Same output on every backend.

struct Foo { kind: "foo"; x: int32; }
struct Bar { kind: "bar"; y: int32; }

function first<T>(a: T | Foo): T | Foo { return a; }
function last<T>(a: Foo | T): Foo | T { return a; }
function show(u: Bar | Foo): string { return u.kind == "foo" ? "foo" : "bar"; }

const bar: Bar = { kind: "bar", y: 9 };
const foo: Foo = { kind: "foo", x: 1 };
const kept = first<Bar>(foo);
console.log(`${show(kept)} ${show(first<Bar>(bar))} ${show(last<Bar>(foo))} ${show(last<Bar>(bar))} ${kept.kind}`);
