// The typed-array core of the native backends: one owned byte payload per ArrayBuffer, and views
// that share it. A view reads and writes its elements as a Span of its element type over the
// payload, so the subscripts, `set` and `join` are one body for every element type. The JS backend
// binds the same names to the host's classes (index.jms).

import { Math, ceil, floor, round } from "../math";

function relativeIndex(index: number, length: number): number {
	const whole = index < 0 ? Math.ceil(index) : Math.floor(index);
	if (whole < 0) return whole + length < 0 ? 0 : whole + length;
	return whole > length ? length : whole;
}

function wholeLength(value: number, name: string): number {
	if (!(value >= 0) || value != Math.floor(value) || value > 9007199254740991) throw new RangeError(`Invalid ${name}: ${value}`);
	return value;
}

function viewStart(buffer: ArrayBuffer, byteOffset: number, per: number, name: string): number {
	const offset = wholeLength(byteOffset, "typed array offset");
	if (offset % per != 0) throw new RangeError(`start offset of ${name} should be a multiple of ${per}`);
	if (offset > buffer.bytes.length) throw new RangeError(`Start offset ${offset} is outside the bounds of the buffer`);
	return offset;
}

function viewLength(buffer: ArrayBuffer, offset: number, length: number, per: number, name: string): number {
	if (length < 0) {
		if (buffer.bytes.length % per != 0) throw new RangeError(`byte length of ${name} should be a multiple of ${per}`);
		return (buffer.bytes.length - offset) / per;
	}
	const count = wholeLength(length, "typed array length");
	if (offset + count * per > buffer.bytes.length) throw new RangeError(`Invalid typed array length: ${count}`);
	return count;
}

// ToUint8Clamp: NaN to 0, out of range to the nearest end, a tie to the even neighbour.
export function clampUint8(value: number): uint8 {
	if (!(value > 0)) return 0;
	if (value >= 255) return 255;
	const nearest = Math.round(value);
	return (nearest - value == 0.5 && nearest % 2 != 0 ? nearest - 1 : nearest) as uint8;
}

export class ArrayBuffer {
	bytes: uint8[];

	constructor(byteLength: number = 0) {
		this.bytes = new Array<uint8>(wholeLength(byteLength, "array buffer length"));
	}

	get byteLength(): number { return this.bytes.length; }

	slice(begin: number = 0, end: number = this.bytes.length): ArrayBuffer {
		const from = relativeIndex(begin, this.bytes.length);
		const to = relativeIndex(end, this.bytes.length);
		const out = new ArrayBuffer(to > from ? to - from : 0);
		for (let i = 0; i < out.bytes.length; i++) out.bytes[i] = this.bytes[from + i];
		return out;
	}
}

@builtin("TypedArray")
export class TypedArray<T> {
	readonly buffer: ArrayBuffer;
	readonly byteOffset: number;
	readonly length: number;

	constructor(buffer: ArrayBuffer, byteOffset: number, length: number) {
		this.buffer = buffer;
		this.byteOffset = byteOffset;
		this.length = length;
	}

	set(source: Readonly<Span<T>>, offset: number = 0): void {
		const at = wholeLength(offset, "offset");
		if (at + source.length > this.length) throw new RangeError("offset is out of bounds");
		const into: Span<T> = this;
		for (let i = 0; i < source.length; i++) into[at + i] = source[i];
	}

	join(separator: string = ","): string {
		const elements: Readonly<Span<T>> = this;
		let out = "";
		for (let i = 0; i < elements.length; i++) {
			if (i > 0) out += separator;
			out += (elements[i] as number).toString();
		}
		return out;
	}

	toString(): string { return this.join(","); }
}

export class Int8Array extends TypedArray<int8> {
	static readonly BYTES_PER_ELEMENT: number = 1;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<int8[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<int8[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 1), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 1, "Int8Array");
			super(source, offset, viewLength(source, offset, length, 1, "Int8Array"));
		} else {
			super(new ArrayBuffer(source.length * 1), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<int8>>): Int8Array {
		const out = new Int8Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 1; }

	subarray(begin: number = 0, end: number = this.length): Int8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Int8Array(this.buffer, this.byteOffset + from * 1, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Int8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Int8Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: int8, begin: number = 0, end: number = this.length): Int8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<int8> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}

export class Uint8Array extends TypedArray<uint8> {
	static readonly BYTES_PER_ELEMENT: number = 1;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<uint8[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<uint8[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 1), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 1, "Uint8Array");
			super(source, offset, viewLength(source, offset, length, 1, "Uint8Array"));
		} else {
			super(new ArrayBuffer(source.length * 1), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<uint8>>): Uint8Array {
		const out = new Uint8Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 1; }

	subarray(begin: number = 0, end: number = this.length): Uint8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Uint8Array(this.buffer, this.byteOffset + from * 1, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Uint8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Uint8Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: uint8, begin: number = 0, end: number = this.length): Uint8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<uint8> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}

export class Uint8ClampedArray extends TypedArray<uint8> {
	static readonly BYTES_PER_ELEMENT: number = 1;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<number[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<number[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 1), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 1, "Uint8ClampedArray");
			super(source, offset, viewLength(source, offset, length, 1, "Uint8ClampedArray"));
		} else {
			super(new ArrayBuffer(source.length * 1), 0, source.length);
			const into: Span<uint8> = this;
			for (let i = 0; i < source.length; i++) into[i] = clampUint8(source[i]);
		}
	}

	static from(source: Readonly<Span<number>>): Uint8ClampedArray {
		const out = new Uint8ClampedArray(source.length);
		const into: Span<uint8> = out;
		for (let i = 0; i < source.length; i++) into[i] = clampUint8(source[i]);
		return out;
	}

	get byteLength(): number { return this.length * 1; }

	subarray(begin: number = 0, end: number = this.length): Uint8ClampedArray {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Uint8ClampedArray(this.buffer, this.byteOffset + from * 1, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Uint8ClampedArray {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Uint8ClampedArray(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: number, begin: number = 0, end: number = this.length): Uint8ClampedArray {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<uint8> = this;
		for (let i = from; i < to; i++) into[i] = clampUint8(value);
		return this;
	}
}

export class Int16Array extends TypedArray<int16> {
	static readonly BYTES_PER_ELEMENT: number = 2;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<int16[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<int16[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 2), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 2, "Int16Array");
			super(source, offset, viewLength(source, offset, length, 2, "Int16Array"));
		} else {
			super(new ArrayBuffer(source.length * 2), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<int16>>): Int16Array {
		const out = new Int16Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 2; }

	subarray(begin: number = 0, end: number = this.length): Int16Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Int16Array(this.buffer, this.byteOffset + from * 2, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Int16Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Int16Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: int16, begin: number = 0, end: number = this.length): Int16Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<int16> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}

export class Uint16Array extends TypedArray<uint16> {
	static readonly BYTES_PER_ELEMENT: number = 2;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<uint16[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<uint16[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 2), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 2, "Uint16Array");
			super(source, offset, viewLength(source, offset, length, 2, "Uint16Array"));
		} else {
			super(new ArrayBuffer(source.length * 2), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<uint16>>): Uint16Array {
		const out = new Uint16Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 2; }

	subarray(begin: number = 0, end: number = this.length): Uint16Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Uint16Array(this.buffer, this.byteOffset + from * 2, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Uint16Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Uint16Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: uint16, begin: number = 0, end: number = this.length): Uint16Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<uint16> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}

export class Int32Array extends TypedArray<int32> {
	static readonly BYTES_PER_ELEMENT: number = 4;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<int32[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<int32[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 4), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 4, "Int32Array");
			super(source, offset, viewLength(source, offset, length, 4, "Int32Array"));
		} else {
			super(new ArrayBuffer(source.length * 4), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<int32>>): Int32Array {
		const out = new Int32Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 4; }

	subarray(begin: number = 0, end: number = this.length): Int32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Int32Array(this.buffer, this.byteOffset + from * 4, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Int32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Int32Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: int32, begin: number = 0, end: number = this.length): Int32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<int32> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}

export class Uint32Array extends TypedArray<uint32> {
	static readonly BYTES_PER_ELEMENT: number = 4;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<uint32[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<uint32[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 4), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 4, "Uint32Array");
			super(source, offset, viewLength(source, offset, length, 4, "Uint32Array"));
		} else {
			super(new ArrayBuffer(source.length * 4), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<uint32>>): Uint32Array {
		const out = new Uint32Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 4; }

	subarray(begin: number = 0, end: number = this.length): Uint32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Uint32Array(this.buffer, this.byteOffset + from * 4, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Uint32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Uint32Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: uint32, begin: number = 0, end: number = this.length): Uint32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<uint32> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}

export class Float32Array extends TypedArray<float32> {
	static readonly BYTES_PER_ELEMENT: number = 4;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<float32[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<float32[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 4), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 4, "Float32Array");
			super(source, offset, viewLength(source, offset, length, 4, "Float32Array"));
		} else {
			super(new ArrayBuffer(source.length * 4), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<float32>>): Float32Array {
		const out = new Float32Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 4; }

	subarray(begin: number = 0, end: number = this.length): Float32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Float32Array(this.buffer, this.byteOffset + from * 4, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Float32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Float32Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: float32, begin: number = 0, end: number = this.length): Float32Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<float32> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}

export class Float64Array extends TypedArray<float64> {
	static readonly BYTES_PER_ELEMENT: number = 8;

	constructor();
	constructor(length: number);
	constructor(source: Readonly<float64[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	constructor(source: number | Readonly<float64[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") {
			const count = wholeLength(source, "typed array length");
			super(new ArrayBuffer(count * 8), 0, count);
		} else if (source instanceof ArrayBuffer) {
			const offset = viewStart(source, byteOffset, 8, "Float64Array");
			super(source, offset, viewLength(source, offset, length, 8, "Float64Array"));
		} else {
			super(new ArrayBuffer(source.length * 8), 0, source.length);
			this.set(source);
		}
	}

	static from(source: Readonly<Span<float64>>): Float64Array {
		const out = new Float64Array(source.length);
		out.set(source);
		return out;
	}

	get byteLength(): number { return this.length * 8; }

	subarray(begin: number = 0, end: number = this.length): Float64Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Float64Array(this.buffer, this.byteOffset + from * 8, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Float64Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Float64Array(to > from ? to - from : 0);
		out.set(this.subarray(from, to));
		return out;
	}

	fill(value: float64, begin: number = 0, end: number = this.length): Float64Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const into: Span<float64> = this;
		for (let i = from; i < to; i++) into[i] = value;
		return this;
	}
}
