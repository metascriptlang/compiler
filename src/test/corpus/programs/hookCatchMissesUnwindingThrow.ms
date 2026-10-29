// @stdout: class caught outer, log=fd
// @stdout: struct caught outer, log=fd
// @stdout: deeper caught outer, log=fd
// @stdout: finally caught outer, log=gtFd
// @stdout: quiet caught outer, log=gd
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a destroy hook holding its own try runs while a throw unwinds its scope, and neither its catch nor its finally sees that throw: the caller still catches it and the hook runs its whole body once (old compiler: the hook's catch took the outer error, so the caller printed nothing and the hook stopped at its finally)

let log = "";

function f(n: number): void {
	if (n > 100) throw new Error("big");
	log = log + "f";
}
function g(n: number): void { log = log + "g"; }

class Res { n: number; constructor(n: number) { this.n = n; } }
function onDestroy(this r: Res): void {
	try { f(r.n); } catch (e) { log = log + "[hook caught]"; }
	log = log + "d";
}

struct Plain { n: int32; }
function onDestroy(this r: Plain): void {
	try { f(r.n); } catch (e) { log = log + "[hook caught]"; }
	log = log + "d";
}

function guarded(n: number): void {
	try { f(n); } catch (e) { log = log + "[guarded caught]"; }
}
class Deeper { n: number; constructor(n: number) { this.n = n; } }
function onDestroy(this r: Deeper): void {
	guarded(r.n);
	log = log + "d";
}

class Fin { n: number; constructor(n: number) { this.n = n; } }
function onDestroy(this r: Fin): void {
	try { g(r.n); log = log + "t"; } finally { log = log + "F"; }
	log = log + "d";
}

class Quiet { n: number; constructor(n: number) { this.n = n; } }
function onDestroy(this r: Quiet): void {
	try { g(r.n); } catch (e) { log = log + "[hook caught]"; }
	log = log + "d";
}

function classScope(): void {
	const r = new Res(1);
	if (r.n > 0) throw new Error("outer");
	console.log("unreached");
}
function structScope(): void {
	const r: Plain = { n: 1 };
	if (r.n > 0) throw new Error("outer");
	console.log(`unreached ${r.n}`);
}
function deeperScope(): void {
	const r = new Deeper(1);
	if (r.n > 0) throw new Error("outer");
	console.log("unreached");
}
function finScope(): void {
	const r = new Fin(1);
	if (r.n > 0) throw new Error("outer");
	console.log("unreached");
}
function quietScope(): void {
	const r = new Quiet(1);
	if (r.n > 0) throw new Error("outer");
	console.log("unreached");
}

function run(name: string, scope: () => void): void {
	log = "";
	try {
		scope();
		console.log(`${name} no throw, log=${log}`);
	} catch (e) {
		console.log(`${name} caught ${e.message}, log=${log}`);
	}
}

run("class", classScope);
run("struct", structScope);
run("deeper", deeperScope);
run("finally", finScope);
run("quiet", quietScope);
