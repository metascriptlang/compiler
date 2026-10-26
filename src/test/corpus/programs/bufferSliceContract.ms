// @stdout: slice ok
// @xfail(js): the js Buffer searches backward from the wrong start, reports the whole string a write was given instead of the bytes that fit, drops a copy onto itself, and takes only the lowercase encoding names
// @xfail(esm): the js Buffer searches backward from the wrong start, reports the whole string a write was given instead of the bytes that fit, drops a copy onto itself, and takes only the lowercase encoding names
// note: a backward search from the end, a write clamped to the buffer, an overlapping copy and an upper-case encoding name give node's bytes on C and the raiser.

function check(name: string, ok: boolean): boolean {
	if (!ok) console.log("FAIL " + name);
	return ok;
}

function bytesOf(b: Buffer): string {
	let s = "";
	for (let i = 0; i < b.byteLength(); i++) s += (i > 0 ? " " : "") + b.byteAt(i).toString(16);
	return s;
}

function main(): void {
	let ok = true;

	const hay = Buffer.fromArray([1, 2, 1, 2, 1]);
	const two = Buffer.fromArray([1, 2]);
	ok = check("lastIndexOfBuffer", hay.lastIndexOfBuffer(two, -1) == 2 && hay.lastIndexOfBuffer(two, 1) == 0 && hay.lastIndexOfBuffer(Buffer.alloc(0), -1) == 5) && ok;

	const w = Buffer.alloc(4);
	ok = check("writeHexClamp", w.write("0102030405", 1, 99, "hex") == 3 && bytesOf(w) == "0 1 2 3") && ok;
	ok = check("writeAtEnd", w.write("x", 4, 1, "utf8") == 0) && ok;
	ok = check("upperCaseEncoding", Buffer.fromArray([0xe9]).toStringEncoded("ASCII", 0, 1) == "i") && ok;

	const copyBuf = Buffer.fromArray([1, 2, 3, 4, 5]);
	copyBuf.copyTo(copyBuf, 1, 0, 4);
	ok = check("copyOverlap", bytesOf(copyBuf) == "1 1 2 3 4") && ok;

	console.log(ok ? "slice ok" : "slice FAILED");
}

main();
