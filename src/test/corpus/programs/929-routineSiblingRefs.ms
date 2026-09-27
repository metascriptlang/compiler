// @stdout: sibling=6 nested=12 arrow=8 value=9 loop=6 self=4 none=25
// @xfail(raiser): the Raiser VM resolves a self-referencing routine to 0 (prints 'self=0' where C prints 'self=4')
// note: a nested routine (a nested `function` or a `const` arrow) referenced from a sibling routine, from a closure nested deeper, or passed on as a value by a sibling, is rebuilt at that use over the env it closes over. Before the fix the routine became a field of that env: env -> routine -> env, so every call of the outer function leaked its env on C (drc and orc). The san lane's ledger is the pin: every env below is freed.

type IntFn = (k: int32) => void;

function sibling(): int32 {
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

function nested(): int32 {
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

function arrow(): int32 {
	let total: int32 = 0;
	const add = (k: int32): void => { total = total + k; };
	const addTwice = (k: int32): void => { add(k); add(k); };
	addTwice(4);
	return total;
}

function value(): int32 {
	let total: int32 = 0;
	function add(k: int32): void {
		total = total + k;
	}
	const apply = (f: IntFn, k: int32): void => { f(k); };
	const viaSibling = (): void => { apply(add, 9); };
	viaSibling();
	return total;
}

function loop(): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 3; i++) {
		const addI = (): void => { total = total + i; };
		const twice = (): void => { addI(); addI(); };
		twice();
	}
	return total;
}

function selfNested(): int32 {
	let calls: int32 = 0;
	function count(k: int32): void {
		calls = calls + 1;
		const again = (): void => { if (k > 0) count(k - 1); };
		again();
	}
	count(3);
	return calls;
}

function noCapture(): int32 {
	function sq(k: int32): int32 {
		return k * k;
	}
	const sumSq = (a: int32, b: int32): int32 => sq(a) + sq(b);
	return sumSq(3, 4);
}

function main(): void {
	let churn: int32 = 0;
	for (let n: int32 = 0; n < 50; n++) {
		churn = churn + sibling() + nested() + arrow() + value() + loop() + selfNested() + noCapture();
	}
	console.log(`sibling=${sibling()} nested=${nested()} arrow=${arrow()} value=${value()} loop=${loop()} self=${selfNested()} none=${noCapture()}`);
	console.log(`churn=${churn}`);
}
main();
