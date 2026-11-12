// @skip-js: C and the Raiser own the copies through destroy hooks the DRC runs; JS has no destructors
// @stdout: lit=c,x arg=c,x rest=c,x non=0:c,x made=balanced
let made = 0;
let destroyed = 0;

class D {
	t: string;
	constructor(t: string) { this.t = t; made += 1; }
	onDestroy() { destroyed += 1; }
}

let src: D[] = [];
function reset(): void { src = [new D("c")]; }
function late(): D { src.push(new D("late")); return new D("x"); }
function k(): number { return 0; }
function names(xs: D[]): string { return xs.map((d: D): string => d.t).join(","); }
function many(...xs: D[]): string { return names(xs); }
function pair(n: number, xs: D[]): string { return n.toString() + ":" + names(xs); }

function run(): string {
	reset();
	const lit = names([...src, late()]);
	reset();
	const arg = names([...src, late()]);
	reset();
	const rest = many(...src, late());
	reset();
	const non = pair(k(), [...src, late()]);
	return "lit=" + lit + " arg=" + arg + " rest=" + rest + " non=" + non;
}
const line = run();
src = [];
console.log(line + " made=" + (made == destroyed ? "balanced" : made.toString() + "/" + destroyed.toString()));
