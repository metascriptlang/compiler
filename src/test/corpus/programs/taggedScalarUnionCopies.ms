// @stdout: 2.5 2.5
// @stdout: 2.5 7
// @stdout: 0.5|1|1.5|2
// note: a union of two numeric kinds stores its tag beside the value, and a copy of it is a value of its own: a module global copied to a wider union, a local reassigned after the copy, and an array of them copied by slice
const wide: float64 | int32 = 2.5;
const narrow: number | int32 = wide;
console.log(`${wide} ${narrow}`);

function reassigned(): string {
	let a: float64 | int32 = 2.5;
	const b = a;
	a = 7 as int32;
	return `${b} ${a}`;
}

function inArray(): string {
	const items: (float64 | int32)[] = [];
	for (let i: int32 = 1; i <= 4; i++) {
		if (i % 2 == 0) items.push((i / 2) as int32);
		else items.push(i * 0.5);
	}
	const copy = items.slice(0);
	return copy.map((v) => `${v}`).join("|");
}

console.log(reassigned());
console.log(inArray());
