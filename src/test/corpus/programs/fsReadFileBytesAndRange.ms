// @stdout: len 3008 head 0,1,0,0 range 255,128,127,195 + 4 tail 3 past 0
// @exit: 0
// @skip-raiser
import { Buffer } from "std/core/buffer";
import { readFileBytes, readFileRange } from "std/fs";
const path = "src/test/corpus/programs/readFileBytesFixture/font.bin";
function bytes(b: Buffer, from: number, to: number): string {
	let out = "";
	for (let i = from; i < to; i++) out += (i > from ? "," : "") + b.byteAt(i as int32);
	return out;
}
const whole = readFileBytes(path);
const mid = readFileRange(path, 4, 8);
const tail = readFileRange(path, 3006, 10);
const past = readFileRange(path, 5000, 4);
const missing = readFileRange("src/test/corpus/programs/readFileBytesFixture/none.bin", 0, 4);
if (!whole.ok || !mid.ok || !tail.ok || !past.ok || missing.ok) throw new Error("unexpected result");
console.log(`len ${whole.value.byteLength()} head ${bytes(whole.value, 0, 4)} range ${bytes(mid.value, 0, 4)} + ${mid.value.byteLength() - 4} tail ${tail.value.byteLength() + 1} past ${past.value.byteLength()}`);
