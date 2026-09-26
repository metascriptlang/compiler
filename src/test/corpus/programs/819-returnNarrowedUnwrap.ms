// @stdout: local ab as ab field ab slot ab captured ab array cd class e
// @xfail(raiser): raiser runtime error: attempt to access a nil address — a closure that writes a local it captures crashes the VM (`let n = 0; const f = (): void => { n = 5; }; f();` fails the same way on v0.2.55)
// note: after a null guard (`if (got == null) return …;`) the slot is narrowed, so `return got!` or `return got as Box` is an identity assertion around `got.value`. The return walked that assertion in Consumed mode, which copies a field only in SinkArg mode, so the struct's bits were returned without its copy hook and the local's scope exit then destroyed the arrays the result still pointed at: the local, `as` and captured cases printed empty names, and the field case returned a second owner of `slot.got`'s array. An assignment already walks a conversion in SinkArg mode; the return now does the same.

struct Box {
	names: string[];
	count: int32;
}

interface Slot {
	got: Box | null;
}

class Leaf {
	label: string;
	constructor(label: string) {
		this.label = label;
	}
}

function fresh(): Box {
	return { names: ["a", "b"], count: 2 };
}

function localBang(): Box {
	let got: Box | null = null;
	got = fresh();
	if (got == null) return { names: [], count: 0 };
	return got!;
}

function localAs(): Box {
	let got: Box | null = null;
	got = fresh();
	if (got == null) return { names: [], count: 0 };
	return got as Box;
}

function fieldBang(slot: Slot): Box {
	if (slot.got == null) return { names: [], count: 0 };
	return slot.got!;
}

function capturedBang(): Box {
	let got: Box | null = null;
	const fill = (): void => {
		got = fresh();
	};
	fill();
	if (got == null) return { names: [], count: 0 };
	return got!;
}

function namesBang(): string[] {
	let got: string[] | null = null;
	got = ["c", "d"];
	if (got == null) return [];
	return got!;
}

function leafBang(): Leaf {
	let got: Leaf | null = null;
	got = new Leaf("e");
	if (got == null) return new Leaf("");
	return got!;
}

function main(): void {
	const slot: Slot = { got: fresh() };
	const kept = fieldBang(slot);
	const local = localBang().names.join("");
	const asBox = localAs().names.join("");
	const captured = capturedBang().names.join("");
	console.log(`local ${local} as ${asBox} field ${kept.names.join("")} slot ${slot.got!.names.join("")} captured ${captured} array ${namesBang().join("")} class ${leafBang().label}`);
}

main();
