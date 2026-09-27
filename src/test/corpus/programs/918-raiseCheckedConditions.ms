// @stdout: literal: caught -1 made=2
let log = "";
function check(i: int32): boolean {
	if (i == 2) throw new Error("bad");
	return i < 5;
}
class Box { v: int32; constructor(v: int32) { this.v = v; } }
let made: int32 = 0;
function mk(v: int32): Box { made += 1; return new Box(v); }
function boom(v: int32): Box { if (v >= 0) throw new Error("boom"); return new Box(v); }
function doLoop(): void {
	let i = 0;
	do {
		i += 1;
		if (i == 1) continue;
	} while (check(i));
	log = log + "after do ";
}
function whileLoop(): void {
	let i = 0;
	while (check(i)) i += 1;
	log = log + "after while ";
}
function ifCond(i: int32): void {
	if (i == 0) log = log + "zero ";
	else if (check(i)) log = log + "then ";
	log = log + "after if ";
}
function switchOn(i: int32): void {
	switch (i + (check(i) ? 0 : 1)) {
		case 2: log = log + "two "; break;
		default: log = log + "after switch ";
	}
}
function ternary(i: int32): int32 {
	const n = (check(i) ? 1 : 0) + 1;
	log = log + "after ternary ";
	return n;
}
interface Pair { a: Box; b: Box; }
function literal(): int32 {
	const p: Pair = { a: mk(1), b: boom(2) };
	log = log + "after object ";
	return p.a.v;
}
function arrayLiteral(): int32 {
	const xs: Box[] = [mk(1), boom(2), mk(3)];
	log = log + "after array ";
	return xs.length;
}
function freshCondition(): int32 {
	let i = 0;
	do { i += 1; } while (mk(i).v < 3);
	return i;
}
function run(): void {
	try { doLoop(); } catch (e) { log = log + "caught do "; }
	try { whileLoop(); } catch (e) { log = log + "caught while "; }
	try { ifCond(2); } catch (e) { log = log + "caught if "; }
	try { switchOn(2); } catch (e) { log = log + "caught switch "; }
	try { ternary(2); } catch (e) { log = log + "caught ternary "; }
	console.log(log);
	made = 0;
	let r = 0;
	try { r = literal(); } catch (e) { r = -1; }
	try { r = r + arrayLiteral(); } catch (e) { r = r - 0; }
	console.log("literal: caught " + r.toString() + " made=" + made.toString());
	made = 0;
	console.log("fresh: " + freshCondition().toString() + " made=" + made.toString());
}
run();
