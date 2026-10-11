// @stdout: anon 4 0 | named 9 0 | text hi none | plain 3 5
// note: an anonymous object stored in a `{ ... } | null` slot is released with its fields: the inner object, a named struct it holds and its string are freed with it, not only the outer allocation. The `plain` line frees the same inner types outside a nullable slot, so a missed release shows as an alloc/destroy imbalance on the SAN ledger.

interface Leaf { v: int32 }
interface AnonInAnon { inner: { deep: { v: int32 } } | null }
interface NamedInAnon { inner: { deep: Leaf } | null }
interface TextInAnon { inner: { s: string } | null }

function anon(b: AnonInAnon): int32 { return b.inner == null ? 0 : b.inner.deep.v; }
function named(b: NamedInAnon): int32 { return b.inner == null ? 0 : b.inner.deep.v; }
function text(b: TextInAnon): string { return b.inner == null ? "none" : b.inner.s; }

const a = `${anon({ inner: { deep: { v: 4 } } })} ${anon({ inner: null })}`;
const n = `${named({ inner: { deep: { v: 9 } } })} ${named({ inner: null })}`;
const t = `${text({ inner: { s: "h" + "i" } })} ${text({ inner: null })}`;
function plain(): string {
	const inner: { v: int32 } = { v: 3 };
	const leaf: Leaf = { v: 5 };
	return `${inner.v} ${leaf.v}`;
}
console.log(`anon ${a} | named ${n} | text ${t} | plain ${plain()}`);
