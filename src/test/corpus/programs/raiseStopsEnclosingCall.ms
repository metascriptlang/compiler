// @stdout: wrong: none
let log: string[] = [];
struct Pt { x: int32; y: int32; }
class K {
	v: int32 = 0;
	add(n: int32): int32 { log.push("add"); return this.v + n; }
	label(): string { log.push("label"); return "k"; }
}
function thrower(n: int32): int32 {
	if (n > 0) throw new Error("bad");
	return n;
}
function strThrower(n: int32): string {
	if (n > 0) throw new Error("bad");
	return "ok";
}
function ptThrower(n: int32): Pt {
	if (n > 0) throw new Error("bad");
	return { x: n, y: n };
}
function mk(n: int32): K {
	if (n > 0) throw new Error("bad");
	return new K();
}
function side(tag: string, v: int32): int32 { log.push(tag); return v; }
function sideS(tag: string, s: string): string { log.push(tag); return s; }
function sideP(tag: string, p: Pt): int32 { log.push(tag); return p.x + p.y; }
function two(a: int32, b: int32): int32 { log.push("two"); return a + b; }
class Acc {
	total: int32 = 0;
	add(v: int32): int32 { log.push("acc"); this.total += v; return this.total; }
	direct(): void { this.add(thrower(1)); }
	stored(): void { this.total = this.add(side("inner", thrower(1))); }
	returned(): int32 { return this.add(thrower(1)); }
}
const wrong: string[] = [];
function run(name: string, f: () => void, expected: string = "caught"): void {
	log = [];
	try { f(); log.push("no-throw"); } catch (e) { log.push("caught"); }
	const got = log.join(",");
	console.log(`${name}: ${got}`);
	if (got != expected) wrong.push(name);
}
function expect(name: string, got: string, expected: string): void {
	console.log(`${name} ${got}`);
	if (got != expected) wrong.push(name);
}
function sole(): void { side("outer", thrower(1)); }
function returns(): int32 { return side("outer", thrower(1)); }

let counter: int32 = 0;
let assigned: int32 = 0;
let y: int32 = 0;
const cells: int32[] = [0, 0, 0];
run("sole arg", () => { sole(); });
run("first arg", () => { two(thrower(1), side("second", 1)); });
run("second arg", () => { two(side("first", 1), thrower(1)); }, "first,caught");
run("binop operand", () => { side("outer", thrower(1) + 1); });
run("return", () => { returns(); });
run("arrow body", () => { const h = (): int32 => side("outer", thrower(1)); h(); });
run("deeper", () => { side("o", side("m", thrower(1))); });
run("deeper still", () => { side("o", side("m", side("n", thrower(1)))); });
run("template", () => { console.log(`${side("t", thrower(1))}`); });
run("template second part", () => { console.log(`${side("t1", 1)}-${side("t2", thrower(1))}`); }, "t1,caught");
run("assign", () => { y = side("assign", thrower(1)); });
run("const init", () => { const z = side("init", thrower(1)); side("after", z); });
run("string arg", () => { sideS("outer", strThrower(1)); });
run("string length", () => { side("outer", strThrower(1).length); });
run("struct arg", () => { sideP("outer", ptThrower(1)); });
run("receiver", () => { side("outer", mk(1).add(1)); });
run("receiver method", () => { side("outer", mk(1).label().length); });
run("method direct", () => { new Acc().direct(); });
run("method stored", () => { new Acc().stored(); });
run("method return", () => { new Acc().returned(); });
run("throw arg", () => { throw new Error(sideS("msg", strThrower(1))); });
run("update first", () => { two(counter++, thrower(1)); });
expect("counter", `${counter}`, "1");
run("pre-increment first", () => { two(++assigned, thrower(1)); });
expect("assigned", `${assigned}`, "1");
run("index target", () => { cells[thrower(1)] = 7; });
run("index update", () => { cells[thrower(1)]++; });
expect("cells", cells.join(","), "0,0,0");
function throwArg(): void { throw new Error(sideS("msg", strThrower(1))); }
log = [];
try { throwArg(); } catch (e) { expect("throw arg", `${log.join(",")}:${(e as Error).message}`, ":bad"); }
console.log(`wrong: ${wrong.length == 0 ? "none" : wrong.join(",")}`);
