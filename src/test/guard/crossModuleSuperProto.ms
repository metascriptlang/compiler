// A `super(args)` call whose parent class lives in another module must emit a
// prototype for the parent's `_init` in the CONSUMING module. Nim's
// genProcNoForward declares a proc in every module that uses it; MetaScript
// only wired that proto into the NewExpr path, so the super path inherited a
// declaration only when the same module happened to `new` the parent too.
//
// RED MEANS: the C backend emits `Shape_init((Shape*)this, w)` with no
// declaration in scope and the build dies at
//   error: call to undeclared function 'Shape_init'
//
// GUARD-BALANCE Sq

import { exit } from "std/process";
import { Shape } from "./fixtures/crossModuleCtorBase";

class Sq extends Shape {
	h: number;
	constructor(w: number, h: number) {
		super(w);
		this.h = h;
	}
}

function main(): void {
	const s = new Sq(9, 4);
	if (s.w !== 9) {
		console.log("FAIL: parent field through cross-module super, w=" + s.w.toString());
		exit(1);
	}
	if (s.h !== 4) {
		console.log("FAIL: child field after super, h=" + s.h.toString());
		exit(1);
	}
	console.log("crossModuleSuperProto ok");
}

main();
