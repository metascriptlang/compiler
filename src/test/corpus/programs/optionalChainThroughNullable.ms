// @stdout: inline=4,0 named=4,0 class=4,0 bare=4,null nested=4,0,0 local=4,0 field=7,null
// note: `x?.f` tests `x` for null and reads the field only when `x` holds a value; the read is `T | null`, so `??` supplies the fallback. The object is tested itself, not the value behind it, whether it is an inline object, a named struct or a class.

interface Inline { inner: { v: int32 } | null }
interface Named { v: int32 }
interface ByName { inner: Named | null }
class Leaf { v: int32 = 4; }
interface ByClass { inner: Leaf | null }
interface Deep { inner: { deep: { v: int32 } | null } | null }
interface Holder { o: int32 | null }

function readInline(b: Inline): int32 { return b.inner?.v ?? 0; }
function readNamed(b: ByName): int32 { return b.inner?.v ?? 0; }
function readClass(b: ByClass): int32 { return b.inner?.v ?? 0; }
function readBare(b: Inline): int32 | null { return b.inner?.v; }
function readDeep(b: Deep): int32 { return b.inner?.deep?.v ?? 0; }
function readLocal(i: { v: int32 } | null): int32 { return i?.v ?? 0; }
function readField(h: Holder | null): int32 | null { return h?.o; }

function shown(v: int32 | null): string {
	return v == null ? "null" : v.toString();
}

const inline = `${readInline({ inner: { v: 4 } })},${readInline({ inner: null })}`;
const named = `${readNamed({ inner: { v: 4 } })},${readNamed({ inner: null })}`;
const byClass = `${readClass({ inner: new Leaf() })},${readClass({ inner: null })}`;
const bare = `${shown(readBare({ inner: { v: 4 } }))},${shown(readBare({ inner: null }))}`;
const nested = `${readDeep({ inner: { deep: { v: 4 } } })},${readDeep({ inner: { deep: null } })},${readDeep({ inner: null })}`;
const local = `${readLocal({ v: 4 })},${readLocal(null)}`;
const field = `${shown(readField({ o: 7 }))},${shown(readField(null))}`;
console.log(`inline=${inline} named=${named} class=${byClass} bare=${bare} nested=${nested} local=${local} field=${field}`);
