// @stdout: nested: rS3S4 4
// @xfail(raiser): Raiser keeps the eager spread lowering (no conditional-expression pass), so a conditional or per-iteration spread runs once, first
let log = "";
function side(v: int32): int32 { log = log + "S" + v.toString(); return v; }
function lead(): int32 { log = log + "a"; return 1; }
function arr(): int32[] { log = log + "r"; return [5, 6]; }
function take(x: int32, ys: int32[]): int32 { return x + ys.length; }
function pick(flag: boolean, a: int32[]): int32[] {
	const r: int32[] = flag ? [...a, side(7)] : [0];
	return r;
}
function run(): void {
	const a: int32[] = [1, 2];
	log = "";
	const t = pick(false, a);
	console.log("ternary: " + log + " " + t.length.toString());
	log = "";
	const g = a.length > 5 && [...a, side(8)].length > 0;
	console.log("and: " + log + " " + (g ? "y" : "n"));
	log = "";
	let n = 0;
	while (n < 3 && [...a, side(9)].length == 3) n = n + 1;
	console.log("while: " + log + " " + n.toString());
	log = "";
	let total = 0;
	for (let i = 0; i < [...arr(), 1].length; i += 1) total += 1;
	console.log("for: " + log + " " + total.toString());
	log = "";
	const k = take(lead(), [...arr(), side(7)]);
	console.log("arg: " + log + " " + k.toString());
	log = "";
	const m: int32[] = [side(1), ...arr(), side(2)];
	console.log("elems: " + log + " " + m.length.toString());
	log = "";
	const nested: int32[] = [...[...arr(), side(3)], side(4)];
	console.log("nested: " + log + " " + nested.length.toString());
}
run();
