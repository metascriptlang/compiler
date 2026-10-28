// @stdout: try 1001 [0123 err at 5 [01234 | plus 1001 [0123 | match 1001 [0x2x | await 1001 [0123 | param pqc | captured abc abc abc | written 11
// note: a string append whose operand is a `try`, a `match` or an `await` keeps the target in place when only its own routine names it, so a loop of them stays linear; when a closure writes the target, or the operand itself writes it (`k += try ten(k++)`), the target is still read before the operand runs, as TS does.

function cell(i: int32): Result<string, string> { return Result.ok(String(i % 10)); }
function failAt(i: int32, bad: int32): Result<string, string> { return i == bad ? Result.err(`err at ${i}`) : cell(i); }
async function later(i: int32): Promise<string> { return String(i % 10); }
function take(s: string): Result<string, string> { return Result.ok("c"); }

function viaTry(n: int32): Result<string, string> {
	let out = "[";
	for (let i: int32 = 0; i < n; i++) out += try cell(i);
	return Result.ok(out);
}
function viaTryFails(n: int32, seen: string[]): Result<string, string> {
	let out = "[";
	for (let i: int32 = 0; i < n; i++) {
		seen[0] = out;
		out += try failAt(i, 5);
	}
	return Result.ok(out);
}
function viaPlus(n: int32): Result<string, string> {
	let out = "[";
	for (let i: int32 = 0; i < n; i++) out = out + try cell(i);
	return Result.ok(out);
}
function viaMatch(n: int32): string {
	let out = "[";
	for (let i: int32 = 0; i < n; i++) out += match (i % 2) { 0 => String(i % 10), _ => "x" };
	return out;
}
async function viaAwait(n: int32): Promise<string> {
	let out = "[";
	for (let i: int32 = 0; i < n; i++) out += await later(i);
	return out;
}
function viaParam(s: string): Result<string, string> {
	s += try take(s);
	return Result.ok(s);
}
function capturedTry(): Result<string, string> {
	let c = "ab";
	const w = (): Result<string, string> => { c = "Z"; return Result.ok("c"); };
	c += try w();
	return Result.ok(c);
}
function capturedPlus(): Result<string, string> {
	let c = "ab";
	const w = (): Result<string, string> => { c = "Z"; return Result.ok("c"); };
	c = c + try w();
	return Result.ok(c);
}
async function capturedAwait(): Promise<string> {
	let c = "ab";
	const w = async (): Promise<string> => { c = "Z"; return "c"; };
	c += await w();
	return c;
}
function ten(v: int32): Result<int32, string> { return Result.ok(10); }
function writtenInOperand(): Result<int32, string> {
	let k: int32 = 1;
	k += try ten(k++);
	return Result.ok(k);
}

function head(s: string): string { return `${s.length} ${s.slice(0, 5)}`; }

async function main(): Promise<void> {
	const t = viaTry(1000);
	const seen: string[] = [""];
	const f = viaTryFails(1000, seen);
	const p = viaPlus(1000);
	const param = viaParam("pq");
	const ct = capturedTry();
	const cp = capturedPlus();
	const named = writtenInOperand();
	console.log(`try ${t.ok ? head(t.value) : "-"} ${f.ok ? "-" : f.error} ${seen[0]} | plus ${p.ok ? head(p.value) : "-"} | match ${head(viaMatch(1000))} | await ${head(await viaAwait(1000))} | param ${param.ok ? param.value : "-"} | captured ${ct.ok ? ct.value : "-"} ${cp.ok ? cp.value : "-"} ${await capturedAwait()} | written ${named.ok ? named.value : -1}`);
}
main();
