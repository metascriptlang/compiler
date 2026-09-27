// @stdout: even v4
// @xfail(raiser): the Raiser VM does not re-read the loop condition after a continue inside a switch (prints 'after switch s3' where C prints 's4')
// note: `continue` goes through the loop condition (do-while) or the update (for) in the last-read analysis. It used to jump back to the body start, so a value moved before `continue` was read by the condition after the move.

class Box { v: string; n: int32; constructor(v: string, n: int32) { this.v = v; this.n = n; } }

function doWhile(): void {
	let b = new Box("start", 0);
	const kept: Box[] = [];
	let n: int32 = 0;
	do {
		n++;
		b = new Box("v" + String(n), n);
		if (n % 2 == 1) {
			kept.push(b);
			continue;
		}
		console.log("even " + b.v);
	} while (b.n < 4);
	console.log(kept.length);
}

function forUpdate(): void {
	let b = new Box("start", 0);
	const kept: Box[] = [];
	for (let i: int32 = 0; i < 4; i = b.n) {
		b = new Box("f" + String(i + 1), i + 1);
		if (i % 2 == 0) {
			kept.push(b);
			continue;
		}
		console.log("odd " + b.v);
	}
	console.log(kept.length);
}

function continueThroughSwitch(): void {
	let b = new Box("start", 0);
	const kept: Box[] = [];
	let n: int32 = 0;
	do {
		n++;
		b = new Box("s" + String(n), n);
		switch (n) {
			case 1:
				if (n == 1) break;
				console.log("never");
				break;
			case 3:
				kept.push(b);
				continue;
		}
		console.log("after switch " + b.v);
	} while (b.n < 4);
	console.log(kept.length);
}

doWhile();
forUpdate();
continueThroughSwitch();
