// @xfail(raiser): runs but stdout misses its @stdout line (exit=0)
// @stdout: macro-hoist-gensym PASS
// note: one hoisting macro expanded TWICE in one block. Each expansion declares its prefix under the name the macro spelled, so two of them put two `tpl` into one scope. The checker merged the second into the first symbol; C survived only because the lambda-lifting rename happened to split them, and the JS lane emitted `const tpl` twice — a SyntaxError before the first line ran. The contract is one slot per SITE (704): `T1T2`, never `T1T1`, and the initializers run once each however often `render` runs. The statement shape is the same macro family called for its effect: the trailing expression of the splice is the value, it has to stay in the statement slot as a checked expression — it used to be dropped on C and to read an unbound name on JS — inside a function and at module top alike. The macro lives in its own module because that is how a component library ships one. Parity C↔JS is the point: the names are made unique in the checker, so both backends see the same two declarations.

import { memo, memoShow } from "./memo";

let builds: int32 = 0;
let seen: string = "";

function buildTemplate(): string {
	builds = builds + 1;
	return "T" + builds.toString();
}

function show(s: string): void {
	seen = seen + s;
}

function render(): string {
	const a = memo();
	const b = memo();
	return a + b;
}

function renderForEffect(): void {
	memoShow();
	memoShow();
}

memoShow();

function main(): void {
	let ok = true;

	if (seen != "T1") ok = false;
	if (render() != "T2T3") ok = false;
	if (render() != "T2T3") ok = false;
	renderForEffect();
	renderForEffect();
	if (seen != "T1T4T5T4T5") ok = false;
	if (builds != 5) ok = false;

	if (ok) {
		console.log("macro-hoist-gensym PASS");
	} else {
		console.log("macro-hoist-gensym FAIL builds=" + builds.toString() + " seen=" + seen);
	}
}

main();
