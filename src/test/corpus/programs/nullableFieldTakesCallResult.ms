// @stdout: a2|l23|n2
// @stdout: 1|2
// note: a call result moved into a nullable field is emptied by its own type's hook, not the field's: a plain closure and a string reassigned in a loop, and a generic setter whose parameter is a union
type Setter = (v: float64) => void;
type Update<T> = (v: T | ((prev: T) => T)) => void;

const seen: string[] = [];
const updates: string[] = [];

function makeSetter(tag: string): Setter {
	return (v: float64): void => { seen.push(`${tag}${v}`); };
}

function makeName(n: int32): string { return `n${n}`; }

function makeUpdate<T>(init: T): Update<T> {
	let value = init;
	updates.push(`${value}`);
	return (v: T | ((prev: T) => T)): void => {
		value = v as T;
		updates.push(`${value}`);
	};
}

interface Cell { setter: Setter | null; name: string | null; }
interface Holder { update: Update<number> | null; }

function plain(): void {
	const cell: Cell = { setter: null, name: null };
	cell.setter = makeSetter("a");
	cell.name = makeName(1);
	if (cell.setter !== null) cell.setter(2);
	for (let i: int32 = 0; i < 3; i++) {
		cell.setter = makeSetter(`l${i}`);
		cell.name = makeName(i);
	}
	if (cell.setter !== null) cell.setter(3);
	seen.push(cell.name ?? "none");
}

function generic(): void {
	const holder: Holder = { update: null };
	holder.update = makeUpdate(1 as number);
	if (holder.update !== null) holder.update(2);
}

plain();
generic();
console.log(seen.join("|"));
console.log(updates.join("|"));
