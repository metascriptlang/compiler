// bug150 — a struct field or destructured parameter of accessor type had to be called with `()` to be read
// Symptom: `props.count * 2`, `props.items.length`, `const { count } = props; count + 1` and a callback
//          `(item: Acc<T>, i: Acc<number>) => item + i` were type errors — the member read was the closure.
// Root cause: same as bug154 on the MemberExpr read path (checkMemberExpr returns the field type untouched).
// Fix: autoCallIfAccessor runs after checkMemberExpr as well; the object of a member expression is read with the
//      suppression reset, so `count.toString()` becomes `count().toString()`.

type Acc150<T> = distinct (() => T);

function makeSignal150<T>(v: T): [Acc150<T>, (n: T) => void] {
	let cur = v;
	return [(() => cur) as Acc150<T>, (n: T) => { cur = n; }];
}

interface Props150 {
	count: Acc150<number>;
	items: Acc150<number[]>;
	label: string;
}

function twice150(p: Props150): number {
	const { count } = p;
	return count * 2;
}

function total150(props: Props150): number {
	let t: number = 0;
	for (const x of props.items) { t = t + x; }
	return t + props.count + props.items.length;
}

function row150(item: Acc150<number>, i: Acc150<number>): number {
	return item * 10 + i;
}

test "a destructured accessor binding is read as its value" {
	const [c, setC] = makeSignal150<number>(4);
	const [items, setItems] = makeSignal150<number[]>([1, 2]);
	const props: Props150 = { count: c, items: items, label: "x" };
	assert twice150(props) === 8;
	setC(5);
	assert twice150(props) === 10;
}

test "a member read of accessor type is read as its value" {
	const [c, setC] = makeSignal150<number>(1);
	const [items, setItems] = makeSignal150<number[]>([1, 2]);
	const props: Props150 = { count: c, items: items, label: "x" };
	assert total150(props) === 6;
	setItems([7]);
	assert total150(props) === 9;
}

test "accessor callback parameters are read as their values" {
	const [c, setC] = makeSignal150<number>(2);
	const [i, setI] = makeSignal150<number>(3);
	assert row150(c, i) === 23;
	setI(4);
	assert row150(c, i) === 24;
}

test "a member callee reads the accessor's value first" {
	const [c, setC] = makeSignal150<number>(12);
	const props: Props150 = { count: c, items: makeSignal150<number[]>([])[0], label: "x" };
	assert c.toString() === "12";
	assert props.count.toString() === "12";
}
