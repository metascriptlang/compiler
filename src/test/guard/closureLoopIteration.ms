// nim-guard: a loop iteration's closure env is freed with the closures made in it, and a cycle
// through it is collected under orc.
//
// Nim: lambdalifting.nim:353 getEnvTypeForOwner gives each owner one env, and system.nim:2938
// closureScope makes that owner a proc called once per iteration, so each iteration gets its own
// env with `up` to the enclosing one (:381 createUpField). A closure made in the loop points to
// its iteration's env; nothing points back unless the program stores the closure in a variable
// that closure captures. Nim test: tests/closure/tclosure.nim.
// NIM-REF: TR-11.
//
// clOuterArray keeps its closures in an array no closure captures: the envs form no cycle and are
// freed on drc and orc. clSelfArray's closures capture the array that holds them:
// env -> array -> closure -> env, which drc leaks by design and orc collects.
//
// RED MEANS a loop iteration's env outlives the closures made in it (acyclic case), a cycle through
// it is not collected under orc, or a closure made in a loop lost a write to a shared variable —
// run /trace-nim on lambda lifting's per-iteration env.
//
// GUARD-BALANCE dollarEnv_clOuterArray_shared_
// GUARD-BALANCE dollarEnv_clOuterArray_loop1_
// GUARD-BALANCE-ORC dollarEnv_clSelfArray_shared_
// GUARD-BALANCE-ORC dollarEnv_clSelfArray_loop3_
// GUARD-JS

type ClGet = () => int32;

function clOuterArray(): int32 {
	let total: int32 = 0;
	const fns: ClGet[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		fns.push((): int32 => { total = total + i; return total; });
	}
	let s: int32 = 0;
	for (const f of fns) s = s + f();
	return s + total;
}

function clSelfArray(): int32 {
	let total: int32 = 0;
	const fns: ClGet[] = [];
	for (let i: int32 = 0; i < 3; i++) {
		fns.push((): int32 => { total = total + i + fns.length; return total; });
	}
	let s: int32 = 0;
	for (const f of fns) s = s + f();
	return s;
}

function main(): void {
	let outer: int32 = 0;
	let self: int32 = 0;
	for (let n: int32 = 0; n < 200; n++) {
		outer = outer + clOuterArray();
		self = self + clSelfArray();
	}
	console.log(`outer=${outer} self=${self}`);
	if (outer != 1400) throw "GUARD RED: a closure made in a loop lost a write to the function's variable, got=" + outer.toString();
	if (self != 4400) throw "GUARD RED: a closure made in a loop lost a write through a cycle, got=" + self.toString();
	console.log("GUARD-OK");
}
main();
