// bug154 — an accessor (a distinct over a zero-parameter function) had to be called with `()` to be read
// Symptom: `type Acc<T> = distinct (() => T)`; `setC(c + 1)`, `if (c > 1)`, `"" + c`, `for (const x of items)`
//          were type errors — the bare identifier was the closure itself, so React-style component code could not
//          read a signal without parentheses.
// Root cause: the checker had no implicit call — a value read of an accessor type stayed a function value in every
//             position, including the ones whose expected type can never take a function.
// Fix: autoCallIfAccessor — an Identifier or MemberExpr read whose type is a distinct over a zero-parameter function
//      is rewritten into a call (through checkCallExpr, so the distinct peel applies on both backends) at every value
//      position whose expected type is not callable; callee, assignment target and overload pass 1 are suppressed.

type Acc154<T> = distinct (() => T);

function makeSignal154<T>(v: T): [Acc154<T>, (n: T) => void] {
	let cur = v;
	return [(() => cur) as Acc154<T>, (n: T) => { cur = n; }];
}

test "an accessor operand is read as its value" {
	const [c, setC] = makeSignal154<number>(1);
	setC(c + 1);
	assert c === 2;
	setC(c * 10);
	assert c === 20;
}

test "an accessor in a condition and a template literal is read as its value" {
	const [c, setC] = makeSignal154<number>(3);
	let branch = "";
	if (c > 1) { branch = `big ${c}`; } else { branch = "small"; }
	assert branch === "big 3";
	setC(0);
	assert (c > 1 ? "b" : "s") === "s";
}

test "an accessor of an array is iterated and indexed" {
	const [items, setItems] = makeSignal154<number[]>([1, 2, 3]);
	let sum: number = 0;
	for (const x of items) { sum = sum + x; }
	assert sum === 6;
	assert items.length === 3;
	setItems([5]);
	assert items[0] === 5;
}

test "an accessor of a string concatenates as its value" {
	const [name, setName] = makeSignal154<string>("a");
	const s = "" + name + "!";
	assert s === "a!";
	setName("b");
	assert name + name === "bb";
}
