function describe(i: int32): string { return "bad " + i.toString(); }

function throwLocal(i: int32): void {
	const m = describe(i);
	throw m;
}

function throwLocalTwice(i: int32): void {
	const m = describe(i);
	const n = m.length;
	if (n > 0) throw m;
}

function throwConcat(i: int32): void {
	throw "w:" + describe(i);
}

let caught = 0;
for (let i: int32 = 0; i < 50; i += 1) {
	try { throwLocal(i); } catch (e) { caught += 1; }
	try { throwLocalTwice(i); } catch (e) { caught += 1; }
	try { throwConcat(i); } catch (e) { caught += 1; }
}
console.log("caught " + caught.toString());
