// @stdout: writeUInt32LE threw The value of "offset" is out of range. It must be >= 0 and <= 0. Received 2
// @stdout: readUInt32LE threw The value of "offset" is out of range. It must be >= 0 and <= 0. Received 2
// @stdout: readUInt8 threw The value of "offset" is out of range. It must be >= 0 and <= 3. Received 10
// @stdout: readInt16BE threw The value of "offset" is out of range. It must be >= 0 and <= 2. Received -1
// @stdout: readDoubleLE threw Attempt to access memory outside buffer bounds
// @stdout: readBigUInt64LE threw Attempt to access memory outside buffer bounds
// @stdout: writeIntLE threw The value of "offset" is out of range. It must be >= 0 and <= 1. Received 2
// @stdout: readUIntBE threw The value of "offset" is out of range. It must be an integer. Received 0.5
// @stdout: writeUInt8 threw The value of "value" is out of range. It must be >= 0 and <= 255. Received 256
// @stdout: untouched 0 0 0 0
// note: a Buffer field read or write outside the buffer throws Node's RangeError and writes nothing, on every backend.

const b = Buffer.alloc(4);

function attempt(name: string, call: () => string): void {
	try {
		console.log(`${name} ${call()}`);
	} catch (e) {
		console.log(`${name} threw ${(e as Error).message}`);
	}
}

attempt("writeUInt32LE", () => `${b.writeUInt32LE(7, 2)}`);
attempt("readUInt32LE", () => `${b.readUInt32LE(2)}`);
attempt("readUInt8", () => `${b.readUInt8(10)}`);
attempt("readInt16BE", () => `${b.readInt16BE(-1)}`);
attempt("readDoubleLE", () => `${b.readDoubleLE(0)}`);
attempt("readBigUInt64LE", () => `${b.readBigUInt64LE(0)}`);
attempt("writeIntLE", () => `${b.writeIntLE(1, 2, 3)}`);
attempt("readUIntBE", () => `${b.readUIntBE(0.5, 2)}`);
attempt("writeUInt8", () => `${b.writeUInt8(256, 0)}`);
console.log(`untouched ${b[0]} ${b[1]} ${b[2]} ${b[3]}`);
