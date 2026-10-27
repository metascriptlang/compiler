// @stdout: caught ctor|caught nested|ok 3
// note: a constructor that raises after allocating releases its instance on the raise path; one that returns normally still hands it to the caller.

class Strict {
	n: int32;
	constructor(n: int32) {
		if (n < 0) throw new Error("ctor");
		this.n = n;
	}
}

class Holder {
	inner: Strict;
	constructor(n: int32) {
		this.inner = new Strict(n);
	}
}

function build(n: int32): int32 {
	const s = new Strict(n);
	return s.n;
}

let out = "";
try { build(-1); } catch (e) { out += "caught " + (e as Error).message + "|"; }
try { new Holder(-2); } catch (e) { out += "caught nested|"; }
out += "ok " + build(3);
console.log(out);
