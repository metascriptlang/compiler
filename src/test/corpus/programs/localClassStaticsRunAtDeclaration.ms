// @stdout: module 10 static 11 inits 11
// @stdout: twice 12 13 inits 13
// @stdout: managed s1 [1] b1 | s2 [2,2] b2
// @stdout: literal 5 5
// @stdout: nested 21 22 outer 3
// @xfail(san): a managed class static is never destroyed at exit (.inbox/compiler/2026-10-16-class-static-managed-field-never-destroyed-at-exit.md)
// @xfail(raiser): the Raiser cannot read a static of a class declared in a function (.inbox/compiler/2026-10-14-class-declared-in-a-function-loses-its-static-fields.md)
function start(): int32 { return 10; }
let inits: int32 = start();
function bump(): int32 { inits += 1; return inits; }

function readsModule(): int32 {
	class R {
		static a: int32 = bump();
	}
	return R.a;
}

class Box {
	tag: string;
	constructor(tag: string) { this.tag = tag; }
}

let gen: int32 = 0;
function managed(): string {
	gen += 1;
	class M {
		static s: string = `s${gen}`;
		static xs: int32[] = [];
		static box: Box = new Box(`b${gen}`);
		static {
			for (let i = 0; i < gen; i += 1) { M.xs.push(gen); }
		}
	}
	return `${M.s} [${M.xs.join(",")}] ${M.box.tag}`;
}

function literal(): int32 {
	class C {
		static count: int32 = 0;
		static { C.count += 5; }
	}
	return C.count;
}

let outerRuns: int32 = 0;
let innerBase: int32 = 20;
function nested(): int32 {
	innerBase += 1;
	class Outer {
		static runs: int32 = ++outerRuns;
		make(): int32 {
			class Inner {
				static v: int32 = innerBase;
			}
			return Inner.v;
		}
	}
	return new Outer().make();
}

console.log(`module ${inits} static ${readsModule()} inits ${inits}`);
console.log(`twice ${readsModule()} ${readsModule()} inits ${inits}`);
const first = managed();
const second = managed();
console.log(`managed ${first} | ${second}`);
console.log(`literal ${literal()} ${literal()}`);
const n1 = nested();
const n2 = nested();
const n3 = nested();
console.log(`nested ${n1} ${n2} outer ${outerRuns}`);
