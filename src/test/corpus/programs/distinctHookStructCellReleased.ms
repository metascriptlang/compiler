// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: made name ab destroyed 3
// @exit: 0
// note: a user destroy hook on a distinct over a struct runs and then releases the struct itself, whether its fields are scalars or hold a string, so no cell is left live at the end of the program.
struct Plain { n: int32 }
struct Named { name: string; n: int32 }
type PlainHandle = distinct Plain;
type NamedHandle = distinct Named;
let destroyed = 0;
function onDestroy(this h: PlainHandle): void { destroyed += 1; }
function onDestroy(this h: NamedHandle): void { destroyed += 1; }
function mkPlain(): PlainHandle { const p: Plain = { n: 1 }; return p as PlainHandle; }
function mkNamed(): NamedHandle { const p: Named = { name: "a" + "b", n: 2 }; return p as NamedHandle; }
function run(): string {
	const a = mkPlain();
	const b = mkPlain();
	const c = mkNamed();
	return "made name " + (c as Named).name;
}
const text = run();
console.log(text + " destroyed " + destroyed.toString());
