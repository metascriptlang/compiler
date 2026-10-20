// An await outside an async function (module top level, a block in it) raises the rejection at
// the await for every payload kind, so the statement after it never runs and the enclosing catch
// receives the error. Before the fix, C read a pointer, struct, void or nullable payload through
// a wait the compiler took for one that cannot raise: the next statements ran with null, the
// catch ran only at the next raising call, and a nullable payload crashed.
// @stdout: int int|str str|pt pt|box box|reply reply|void void|null null|reject reject|rejectPt rejectPt|nested str|loop 0 1 2|done

interface Reply { status: string; }
struct Pt { x: int32; }
class Box { n: int32 = 0; }

async function fInt(): Promise<int32> { throw new Error("int"); }
async function fStr(): Promise<string> { throw new Error("str"); }
async function fPt(): Promise<Pt> { throw new Error("pt"); }
async function fBox(): Promise<Box> { throw new Error("box"); }
async function fReply(): Promise<Reply> { throw new Error("reply"); }
async function fVoid(): Promise<void> { throw new Error("void"); }
async function fNull(): Promise<string | null> { throw new Error("null"); }
async function fIndex(i: int32): Promise<Box> { throw new Error(`${i}`); }

let log = "";
try { const a = await fInt(); log += `continued ${a}`; } catch (e) { log += `int ${e.message}|`; }
try { await fStr(); log += "continued"; } catch (e) { log += `str ${e.message}|`; }
try { const a = await fPt(); log += `continued ${a.x}`; } catch (e) { log += `pt ${e.message}|`; }
try { const a = await fBox(); log += `continued ${a.n}`; } catch (e) { log += `box ${e.message}|`; }
try { const a = await fReply(); log += `continued ${a.status}`; } catch (e) { log += `reply ${e.message}|`; }
try { await fVoid(); log += "continued"; } catch (e) { log += `void ${e.message}|`; }
try { const a = await fNull(); log += `continued ${a === null ? "null" : a}`; } catch (e) { log += `null ${e.message}|`; }
try { await Promise.reject(new Error("reject")); log += "continued"; } catch (e) { log += `reject ${e.message}|`; }
try {
	const a = await new Promise<Pt>((resolve: (value: Pt) => void, reject: (reason: string | Error) => void): void => { reject(new Error("rejectPt")); });
	log += `continued ${a.x}`;
} catch (e) { log += `rejectPt ${e.message}|`; }
{
	try { const a = await fStr(); log += `continued ${a}`; } catch (e) { log += `nested ${e.message}|`; }
}
log += "loop";
for (let i: int32 = 0; i < 3; i++) {
	try { const b = await fIndex(i); log += ` continued ${b.n}`; } catch (e) { log += ` ${e.message}`; }
}
console.log(`${log}|done`);
