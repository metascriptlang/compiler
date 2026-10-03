// @xfail(raiser): raiser runs no user lifecycle hooks (stdout misses its @stdout line)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: hooks value=1 ref=2 var=3

struct ByValue { id: int32; name: string; }
struct ByRef { id: int32; name: string; }
struct ByVar { id: int32; name: string; }

let valueCalls: int32 = 0;
let refCalls: int32 = 0;
let varCalls: int32 = 0;

function onDestroy(this self: ByValue): void { valueCalls += self.id; }
function onDestroy(this ref self: ByRef): void { refCalls += self.id; }
function onDestroy(this self: Var<ByVar>): void { varCalls += self.id; }

function run(): void {
	let a: ByValue = { id: 1, name: "a" };
	let b: ByRef = { id: 2, name: "b" };
	let c: ByVar = { id: 3, name: "c" };
	console.log(a.name + b.name + c.name);
}

run();
console.log("hooks value=" + valueCalls.toString() + " ref=" + refCalls.toString() + " var=" + varCalls.toString());
