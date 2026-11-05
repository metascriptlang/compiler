// The typed-array core of the native backends: one owned byte payload per ArrayBuffer, and views
// that share it. The JS backend binds the same names to the host's classes (index.jms).

import { Math, ceil, floor } from "../math";

function relativeIndex(index: number, length: number): number {
	const whole = index < 0 ? Math.ceil(index) : Math.floor(index);
	if (whole < 0) return whole + length < 0 ? 0 : whole + length;
	return whole > length ? length : whole;
}

function wholeLength(value: number, name: string): number {
	if (!(value >= 0) || value != Math.floor(value) || value > 9007199254740991) throw new RangeError(`Invalid ${name}: ${value}`);
	return value;
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
			const buffer = new ArrayBuffer(wholeLength(source, "typed array length"));
			super(buffer, 0, buffer.bytes.length);
		} else if (source instanceof ArrayBuffer) {
			const offset = wholeLength(byteOffset, "typed array offset");
			if (offset > source.bytes.length) throw new RangeError(`Start offset ${offset} is outside the bounds of the buffer`);
			const count = length < 0 ? source.bytes.length - offset : wholeLength(length, "typed array length");
			if (offset + count > source.bytes.length) throw new RangeError(`Invalid typed array length: ${count}`);
			super(source, offset, count);
		} else {
			const buffer = new ArrayBuffer(source.length);
			for (let i = 0; i < source.length; i++) buffer.bytes[i] = source[i];
			super(buffer, 0, source.length);
		}
	}

	static from(source: Readonly<Span<uint8>>): Uint8Array {
		const out = new Uint8Array(source.length);
		for (let i = 0; i < source.length; i++) out.buffer.bytes[i] = source[i];
		return out;
	}

	get byteLength(): number { return this.length; }

	subarray(begin: number = 0, end: number = this.length): Uint8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		return new Uint8Array(this.buffer, this.byteOffset + from, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Uint8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		const out = new Uint8Array(to > from ? to - from : 0);
		for (let i = 0; i < out.length; i++) out.buffer.bytes[i] = this.buffer.bytes[this.byteOffset + from + i];
		return out;
	}

	fill(value: uint8, begin: number = 0, end: number = this.length): Uint8Array {
		const from = relativeIndex(begin, this.length);
		const to = relativeIndex(end, this.length);
		for (let i = from; i < to; i++) this.buffer.bytes[this.byteOffset + i] = value;
		return this;
	}

	set(source: Readonly<Span<uint8>>, offset: number = 0): void {
		const at = wholeLength(offset, "offset");
		if (at + source.length > this.length) throw new RangeError("offset is out of bounds");
		for (let i = 0; i < source.length; i++) this.buffer.bytes[this.byteOffset + at + i] = source[i];
	}

	join(separator: string = ","): string {
		let out = "";
		for (let i = 0; i < this.length; i++) {
			if (i > 0) out += separator;
			out += this.buffer.bytes[this.byteOffset + i].toString();
		}
		return out;
	}

	toString(): string { return this.join(","); }
}
