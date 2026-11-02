// @stdout: fits 2 61620000
// @stdout: clamped 2 61626364
// @stdout: at end 0 61626364
// @stdout: offset past threw The value of "offset" is out of range. It must be >= 0 && <= 4. Received 5
// @stdout: negative offset threw The value of "offset" is out of range. It must be >= 0 && <= 4. Received -1
// @stdout: length past threw The value of "length" is out of range. It must be >= 0 && <= 4. Received 5
// @stdout: negative length threw The value of "length" is out of range. It must be >= 0 && <= 4. Received -1
// @stdout: fractional offset threw The value of "offset" is out of range. It must be an integer. Received 1.5
// @stdout: fractional length threw The value of "length" is out of range. It must be an integer. Received 0.5
// @stdout: hex length past threw The value of "length" is out of range. It must be >= 0 && <= 4. Received 9
// @stdout: base64 offset past threw The value of "offset" is out of range. It must be >= 0 && <= 4. Received 6
// @stdout: empty text past threw The value of "offset" is out of range. It must be >= 0 && <= 4. Received 9
// @stdout: after 61626364
// note: buf.write checks offset, then length, against 0..buf.length with Node's RangeError before any encoding, then clamps length to the room left; oracle from Node 24.1.0.

const b = Buffer.alloc(4);

function attempt(name: string, call: () => string): void {
	try {
		console.log(`${name} ${call()}`);
	} catch (e) {
		console.log(`${name} threw ${(e as Error).message}`);
	}
}

attempt("fits", () => `${b.write("ab", 0, 2, "utf8")} ${b.toStringEncoded("hex", 0, 4)}`);
attempt("clamped", () => `${b.write("cdef", 2, 4, "utf8")} ${b.toStringEncoded("hex", 0, 4)}`);
attempt("at end", () => `${b.write("x", 4, 0, "utf8")} ${b.toStringEncoded("hex", 0, 4)}`);
attempt("offset past", () => `${b.write("x", 5, 1, "utf8")}`);
attempt("negative offset", () => `${b.write("x", -1, 1, "utf8")}`);
attempt("length past", () => `${b.write("x", 0, 5, "latin1")}`);
attempt("negative length", () => `${b.write("x", 0, -1, "ascii")}`);
attempt("fractional offset", () => `${b.write("x", 1.5, 1, "utf8")}`);
attempt("fractional length", () => `${b.write("x", 1, 0.5, "utf8")}`);
attempt("hex length past", () => `${b.write("0102", 0, 9, "hex")}`);
attempt("base64 offset past", () => `${b.write("AQI=", 6, 1, "base64")}`);
attempt("empty text past", () => `${b.write("", 9, 1, "utf8")}`);
console.log(`after ${b.toStringEncoded("hex", 0, 4)}`);
