// @stdout: cy cy x 2
// @stdout: b-a 7 ab
// @stdout: pair 3
// @exit: 0

interface Named {
	name: string;
}
type Tagged = { tag: string, id: int32 };
interface Box {
	inner: Named;
}

function nameOf<T extends Named>(item: T): string {
	return item.name;
}
function keep<T extends Named>(item: T): T {
	return item;
}
function tagOf<T extends Tagged>(item: T): string {
	return item.tag + String(item.id);
}
function pair<A extends Named, B extends Tagged>(a: A, b: B): string {
	return a.name + b.tag;
}
function innerName<T extends Box>(box: T): string {
	return box.inner.name;
}

const local = { name: "cy" };
const wide = keep({ name: "x", extra: 2 });
console.log(nameOf({ name: "cy" }), nameOf(local), wide.name, wide.extra);
console.log(tagOf({ id: 7, tag: "b-" }) == "b-7" ? "b-a 7" : "bad", pair({ name: "a", more: 1 }, { id: 3, tag: "b" }));
console.log(innerName({ inner: { name: "pair" } }), keep({ name: "z", n: 3 }).n);
