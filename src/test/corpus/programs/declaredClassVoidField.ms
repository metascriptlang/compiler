// @stdout: 7
// @stdout: 7
// @stdout: make
// @stdout: 9

class Holder { v: void; n: int32; constructor(n: int32) { this.n = n; this.v = null; } }

const shared = new Holder(9);
function make(): Holder {
	console.log("make");
	return shared;
}

const h = new Holder(7);
console.log(h.n);
h.v = null;
const read = h.v;
console.log(h.n);
make().v = null;
console.log(shared.n);
