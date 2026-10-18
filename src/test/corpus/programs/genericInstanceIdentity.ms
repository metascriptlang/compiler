// note: two instances of one generic struct and interface meet in tuples and arrays; each keeps its own layout
struct Wrap<T> { v: T }
interface Slot<T> { held: T }

function pairOfWraps(): [Wrap<number>, Wrap<string>] {
	const a: Wrap<number> = { v: 1 };
	const b: Wrap<string> = { v: "s" };
	return [a, b];
}

function swappedWraps(): [Wrap<string>, Wrap<number>] {
	const a: Wrap<number> = { v: 2 };
	const b: Wrap<string> = { v: "t" };
	return [b, a];
}

const p = pairOfWraps();
const q = swappedWraps();
console.log(p[0].v, p[1].v, q[0].v, q[1].v);

const sameNumbers: [Wrap<number>, Wrap<number>] = [{ v: 5 }, { v: 6 }];
const sameStrings: [Wrap<string>, Wrap<string>] = [{ v: "x" }, { v: "y" }];
console.log(sameNumbers[0].v + sameNumbers[1].v, sameStrings[0].v + sameStrings[1].v);

const slots: [Slot<number>, Slot<string>] = [{ held: 8 }, { held: "h" }];
console.log(slots[0].held, slots[1].held);

type Row = [Wrap<number>, Wrap<string>];
const rows: Row[] = [pairOfWraps(), pairOfWraps()];
console.log(rows.length, rows[1][0].v, rows[1][1].v);

console.log("end");
