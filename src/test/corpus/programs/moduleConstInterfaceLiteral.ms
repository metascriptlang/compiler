// @stdout: m tag t mm 2
// note: a module-level const holding an interface literal with a string field is a valid C static
//   initializer; clang once refused it with "initializer element is not a compile-time constant",
//   a one-character string included (inbox 2026-09-19-top-level-interface-literal-with-string-not-constant,
//   fixed before 013853dd, not bisected). The nested literal is the variant one level deeper.

interface Named { name: string; }
interface Tag { kind: "tag"; label: string; }
interface Outer { inner: Named; count: int32; }

const m: Named = { name: "m" };
const tag: Tag = { kind: "tag", label: "t" };
const outer: Outer = { inner: { name: "mm" }, count: 2 };

console.log(`${m.name} ${tag.kind} ${tag.label} ${outer.inner.name} ${outer.count}`);
