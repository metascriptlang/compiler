// @stdout: i32 -2,258 bytes 0,0,0,0,254,255,255,255,2,1,0,0,0,0,0,0 len=2 bl=8 per=4
// @stdout: u16 8 65534,65535,258 sub 65534,65535 off=6
// @stdout: f64 1.5,-0.25,3 f32 1.100000023841858,2 f32[0]=1.100000023841858
// @stdout: i8 -128,127,5 u32 4294967295,4294967295 i16 300
// @stdout: clamped 255,0,2,2,254 fill 0,0
// @stdout: span 256 258 write -9,258 f64 4.25
// note: the TS typed arrays other than Uint8Array share their buffer's bytes in little-endian order: a view reads and writes its element type at byteOffset (a multiple of BYTES_PER_ELEMENT: typedArrayViewRangeErrors), length counts elements, subarray shares and slice copies; Float32Array rounds to float32 and prints it widened; Uint8ClampedArray clamps any number with ties to even. A typed array passes as a Span of its element type with no copy, on the Raiser too. Same output on every lane as on Node.

const buf = new ArrayBuffer(16);
const bytes = new Uint8Array(buf);
const i32 = new Int32Array(buf, 4, 2);
i32[0] = -2;
i32[1] = 258;
console.log(`i32 ${i32.join(",")} bytes ${bytes.join(",")} len=${i32.length} bl=${i32.byteLength} per=${Int32Array.BYTES_PER_ELEMENT}`);

const u16 = new Uint16Array(buf);
console.log(`u16 ${u16.length} ${u16[2]},${u16[3]},${u16[4]} sub ${u16.subarray(2, 4).join(",")} off=${u16.subarray(3).byteOffset}`);

const f64 = new Float64Array([1.5, -0.25, 3]);
const f32 = new Float32Array([1.1, 2]);
console.log(`f64 ${f64.join(",")} f32 ${f32.join(",")} f32[0]=${f32[0]}`);

const i8 = Int8Array.from([-128, 127, 5]);
const u32 = new Uint32Array(2).fill(4294967295);
console.log(`i8 ${i8.join(",")} u32 ${u32.join(",")} i16 ${new Int16Array([-1, 300]).slice(1).join(",")}`);

const c = new Uint8ClampedArray([300, -5, 1.5, 2.5, 254.5]);
c[0] = 999;
console.log(`clamped ${c.join(",")} fill ${new Uint8ClampedArray(2).fill(-1).join(",")}`);

function sum(xs: Readonly<Span<int32>>): number {
	let total = 0;
	for (let i = 0; i < xs.length; i++) total += xs[i];
	return total;
}

function setFirst(xs: Span<int32>, value: int32): void {
	xs[0] = value;
}

function sumFloat(xs: Readonly<Span<float64>>): number {
	let total: number = 0;
	for (let i = 0; i < xs.length; i++) total += xs[i];
	return total;
}

const total = sum(i32);
setFirst(i32, -9);
console.log(`span ${total} ${sum(new Int32Array(buf, 8, 1))} write ${i32.join(",")} f64 ${sumFloat(f64)}`);

