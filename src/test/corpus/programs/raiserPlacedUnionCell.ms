// @stdout: plain 7
// @stdout: sized 30
struct A { n: int32; }
struct B { s: string; }
type Plain = A | B;

function plain(): void {
	let u: Plain = { n: 1 } as A;
	u = { s: "x" } as B;
	u = { n: 7 } as A;
	console.log("plain 7");
}

function sized(): void {
	let arr: A[1] = [{ n: 1 }];
	arr[0] = { n: 30 };
	console.log("sized " + arr[0].n.toString());
}

plain();
sized();
