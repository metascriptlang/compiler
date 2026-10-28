// @stdout: kernels all-ok
// @skip-js

class Cell { n: number; constructor(n: number) { this.n = n; } }

function nums(label: string, arr: number[]): string {
	let s = label + "=[";
	for (let i = 0; i < arr.length; i += 1) {
		if (i > 0) s = s + ",";
		s = s + arr[i].toString();
	}
	return s + "]" + arr.length.toString();
}

function strs(label: string, arr: string[]): string {
	let s = label + "=[";
	for (let i = 0; i < arr.length; i += 1) {
		if (i > 0) s = s + ",";
		s = s + arr[i];
	}
	return s + "]" + arr.length.toString();
}

function cells(label: string, arr: Cell[]): string {
	let s = label + "=[";
	for (let i = 0; i < arr.length; i += 1) {
		if (i > 0) s = s + ",";
		s = s + arr[i].n.toString();
	}
	return s + "]" + arr.length.toString();
}

function word(i: number): string {
	return "w" + i.toString() + "x";
}

function strings(): void {
	const a: string[] = [word(3), word(1), word(2), word(1), word(0)];
	console.log(strs("start", a));
	console.log("pop=" + a.pop());
	console.log("shift=" + a.shift());
	console.log(strs("after", a));
	a.splice(1, 1);
	console.log(strs("splice1", a));
	a.splice(-1, 1);
	a.splice(9, 1);
	a.splice(0, 0);
	a.splice(0, -3);
	console.log(strs("splice-noop", a));
	a.splice(0, 99, word(7));
	console.log(strs("splice-all", a));
	a.push(word(5));
	a.push(word(4));
	a.splice(-5, 0, word(6));
	a.splice(99, 0, word(8));
	a.splice(1, 1, word(9));
	console.log(strs("splice3", a));
	a.reverse();
	console.log(strs("reverse", a));
	a.sort();
	console.log(strs("sort", a));
	const keep = a.slice(1, 3);
	const tail = a.slice(-2);
	const none = a.slice(3, 1);
	const all = a.slice(-99, 99);
	console.log(strs("slice", keep) + strs(" tail", tail) + strs(" none", none) + strs(" all", all));
	a.fill(word(2));
	const joined = a.concat(keep);
	console.log(strs("fill", a) + strs(" concat", joined));
	a.splice(0, 99);
	const empty: string[] = [];
	console.log("emptyShift=[" + empty.shift() + "]");
	console.log(strs("kept", keep) + strs(" joined", joined));
}

function objects(): void {
	const a: Cell[] = [new Cell(1), new Cell(2), new Cell(3), new Cell(4)];
	const last = a.pop();
	console.log("pop=" + last.n.toString());
	a.splice(1, 1);
	a.splice(1, 0, new Cell(9));
	a.splice(-3, 0, new Cell(8));
	a.splice(99, 0, new Cell(7));
	console.log(cells("cells", a));
	const evicted = new Cell(5);
	a.splice(0, 99, evicted);
	evicted.n = 6;
	console.log(cells("replaced", a));
}

function numbers(): void {
	const a: number[] = [5, 3, 5, 1, 4, 1];
	console.log("pop=" + a.pop().toString());
	console.log("shift=" + a.shift().toString());
	a.sort();
	console.log(nums("sort", a));
	a.reverse();
	console.log(nums("reverse", a));
	a.splice(1, 2);
	a.splice(-1, 1);
	a.splice(9, 1);
	console.log(nums("splice", a));
	a.splice(-4, 0, 7);
	a.splice(99, 0, 8);
	a.splice(1, 1, 6);
	console.log(nums("splice3", a));
	console.log(nums("slice", a.slice(1, -1)) + nums(" tail", a.slice(2)) + nums(" none", a.slice(4, 2)));
	console.log(nums("concat", a.concat([0, 0])));
	a.fill(2);
	console.log(nums("fill", a));
	const empty: number[] = [];
	console.log("emptyShift=" + empty.shift().toString());
}

strings();
objects();
numbers();
console.log("kernels all-ok");
