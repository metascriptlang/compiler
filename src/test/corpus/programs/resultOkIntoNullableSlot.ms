// Parity program — `Result.ok(v)` and `Result.err(e)` take T and E from the Result the context expects,
// so a struct, a string, a number, a class and a generic T reach a `T | null` slot in a return, a typed const and an
// async return, and the value read back is the one written.
//
// @stdout: struct x|string s|int 7|class c|err e|const k|async a|none|generic g|generic int 5
// @exit: 0

struct Post { title: string; }
class Note { text: string = ""; }

function post(v: Post): Result<Post | null, string> { return Result.ok(v); }
function text(v: string): Result<string | null, string> { return Result.ok(v); }
function count(n: int32): Result<int32 | null, string> { return Result.ok(n); }
function note(v: Note): Result<Note | null, string> { return Result.ok(v); }
function fail(e: string): Result<int32, string | null> { return Result.err(e); }
function none(): Result<Post | null, string> { return Result.ok(null); }
function maybe<T>(v: T): Result<T | null, string> { return Result.ok(v); }
async function later(v: string): Promise<Result<string | null, string>> { return Result.ok(v); }

function titleOf(r: Result<Post | null, string>): string {
	if (!r.ok) return "err";
	const p = r.value;
	return p == null ? "none" : p.title;
}

const n = new Note();
n.text = "c";
const typed: Result<Post | null, string> = Result.ok({ title: "k" } as Post);
const t = text("s");
const c = count(7);
const nt = note(n);
const f = fail("e");
const a = await later("a");
const g = maybe<Post>({ title: "g" });
const gi = maybe<int32>(5);
console.log(`struct ${titleOf(post({ title: "x" }))}|string ${t.ok ? t.value : "err"}|int ${c.ok ? c.value : -1}|class ${nt.ok && nt.value != null ? nt.value.text : "err"}|err ${f.ok ? "ok" : f.error}|const ${titleOf(typed)}|async ${a.ok ? a.value : "err"}|${titleOf(none())}|generic ${g.ok ? titleOf(g) : "err"}|generic int ${gi.ok && gi.value != null ? gi.value : -1}`);
