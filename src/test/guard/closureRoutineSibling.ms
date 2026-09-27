// nim-guard: a nested routine referenced from a sibling routine or a nested closure is never an env field.
//
// Nim: lambdalifting.nim:203 interestingVar captures only variables and params; symToClosure
// (:758-785) builds a reference to another routine at the use site, as a closure over the env
// reached by walking `up` from the current one. Nim test: tests/closure/tclosure.nim.
// NIM-REF: TR-11.
//
// RED MEANS a routine binding (nested function or const arrow) is stored in the env it closes
// over again (env -> closure -> env, leaked on every call) — run /trace-nim on lambda lifting's
// routine references.
//
// GUARD-BALANCE dollarEnv_rsSibling_shared_
// GUARD-BALANCE dollarEnv_rsNested_shared_
// GUARD-BALANCE dollarEnv_rsArrow_shared_
// GUARD-BALANCE dollarEnv_rsValue_shared_
// GUARD-BALANCE dollarEnv_rsLoop_shared_
// GUARD-BALANCE dollarEnv_rsSelfNested_shared_
// GUARD-JS

function rsSibling(): int32 {
	let total: int32 = 0;
	function add(k: int32): void {
		total = total + k;
	}
	function addTwice(k: int32): void {
		add(k);
		add(k);
	}
	addTwice(3);
	return total;
}

function rsNested(): int32 {
	let total: int32 = 0;
	function add(k: int32): void {
		total = total + k;
	}
	const run = (): void => {
		add(5);
		const deeper = (): void => { add(7); };
		deeper();
	};
	run();
	return total;
}

function rsArrow(): int32 {
	let total: int32 = 0;
	const add = (k: int32): void => { total = total + k; };
	const addTwice = (k: int32): void => { add(k); add(k); };
	addTwice(4);
	return total;
}

function rsValue(): int32 {
	let total: int32 = 0;
	function add(k: int32): void {
		total = total + k;
	}
	const apply = (f: (k: int32) => void, k: int32): void => { f(k); };
	const viaSibling = (): void => { apply(add, 9); };
	viaSibling();
	return total;
}

function rsLoop(): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		const addI = (): void => { total = total + i; };
		const twice = (): void => { addI(); addI(); };
		twice();
	}
	return total;
}

function rsSelfNested(): int32 {
	let calls: int32 = 0;
	function count(k: int32): void {
		calls = calls + 1;
		const again = (): void => { if (k > 0) count(k - 1); };
		again();
	}
	count(3);
	return calls;
}

function main(): void {
	let sibling: int32 = 0;
	let nested: int32 = 0;
	let arrow: int32 = 0;
	let value: int32 = 0;
	let loop: int32 = 0;
	let selfNested: int32 = 0;
	for (let i: int32 = 0; i < 200; i++) {
		sibling = sibling + rsSibling();
		nested = nested + rsNested();
		arrow = arrow + rsArrow();
		value = value + rsValue();
		loop = loop + rsLoop();
		selfNested = selfNested + rsSelfNested();
	}
	console.log(`sibling=${sibling} nested=${nested} arrow=${arrow} value=${value} loop=${loop} selfNested=${selfNested}`);
	if (sibling != 1200) throw "GUARD RED: a routine called by its sibling lost its captured writes, got=" + sibling.toString();
	if (nested != 2400) throw "GUARD RED: a routine called from a nested closure lost its captured writes, got=" + nested.toString();
	if (arrow != 1600) throw "GUARD RED: a const arrow called by its sibling lost its captured writes, got=" + arrow.toString();
	if (value != 1800) throw "GUARD RED: a routine passed as a value by its sibling lost its captured writes, got=" + value.toString();
	if (loop != 1200) throw "GUARD RED: a routine of one loop iteration called by its sibling computed a wrong value, got=" + loop.toString();
	if (selfNested != 800) throw "GUARD RED: a routine called from a closure in its own body computed a wrong value, got=" + selfNested.toString();
	console.log("GUARD-OK");
}
main();
