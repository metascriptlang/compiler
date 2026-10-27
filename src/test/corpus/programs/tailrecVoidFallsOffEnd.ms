// @stdout: void-tailrec 2 5 7
// A void routine whose self tail call sits on one path returns by running off
// its body's end on the other: a named function, a closure and a method alike.

let total = 0;
function declared(k: int32): void {
	if (k < 0) return declared(0);
	total += k;
}

function viaClosure(): int32 {
	let sum = 0;
	const add = (k: int32): void => {
		if (k < 0) return add(-k);
		sum += k;
	};
	add(-3);
	add(2);
	return sum;
}

class Counter {
	n: int32 = 0;
	bump(k: int32): void {
		if (k > 1) return this.bump(k - 1);
		this.n += 7;
	}
}

declared(-1);
declared(2);
const c = new Counter();
c.bump(4);
console.log("void-tailrec " + total.toString() + " " + viaClosure().toString() + " " + c.n.toString());
