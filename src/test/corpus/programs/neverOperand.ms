// An expression of type never used as an operand raises where it stands: a call, an awaited rejection and an
// interpolation, as an argument after an operand with effects, in a declaration, a condition, a loop head and a template.
// @stdout: nested|a,order|decl|cond|loop|tmpl|ctor|arrow|stmt|done|anested|a,aorder|adecl|acond|aloop|atmpl|atern|done
let log = "";
function fail(m: string): never { throw new Error(m); }
function rej(m: string): Promise<never> { return Promise.reject(new Error(m)); }
function a(): int32 { log += "a,"; return 1; }
function show(n: int32): string { return `${n}`; }
function two(x: int32, y: int32): int32 { return x + y; }
class P { v: int32; constructor(v: int32) { this.v = v; } }
function nested(): string { return show(fail("nested")); }
function order(): int32 { return two(a(), fail("order")); }
function decl(): string { const s = show(fail("decl")); return s + "!"; }
function cond(): string { if (show(fail("cond")) == "x") { return "then"; } return "after"; }
function loop(): string { while (show(fail("loop")) != "") { return "body"; } return "after"; }
function tmpl(): string { return `t${fail("tmpl")}`; }
function ctor(): int32 { return new P(fail("ctor")).v; }
const arrow = (): string => show(fail("arrow"));
function stmt(): void { show(fail("stmt")); log += "unreached,"; }
try { nested(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { order(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { decl(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { cond(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { loop(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { tmpl(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { ctor(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { arrow(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
try { stmt(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
log += "done|";
async function anested(): Promise<string> { return show(await rej("anested")); }
async function aorder(): Promise<int32> { return two(a(), await rej("aorder")); }
async function adecl(): Promise<string> { const s = show(await rej("adecl")); return s + "!"; }
async function acond(): Promise<string> { if (show(await rej("acond")) == "x") { return "then"; } return "after"; }
async function aloop(): Promise<string> { while (show(await rej("aloop")) != "") { return "body"; } return "after"; }
async function atmpl(): Promise<string> { return `t${await rej("atmpl")}`; }
async function atern(): Promise<void> { (show(await rej("atern")) == "x") ? a() : a(); }
async function main(): Promise<void> {
	try { await anested(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
	try { await aorder(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
	try { await adecl(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
	try { await acond(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
	try { await aloop(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
	try { await atmpl(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
	try { await atern(); log += "no-throw,"; } catch (e) { log += `${e.message}|`; }
	console.log(log + "done");
}
main();
