import { ArrayBuffer, Uint8Array } from "../typed/core";
import { decodeUtf8 } from "../typed/utf8";

export interface BufferJson {
	type: string;
	data: number[];
}

export const kMaxLength: number = 2147483647;

function separated(text: string): string {
	let out = "";
	let i = text.length;
	const start = text.startsWith("-") ? 1 : 0;
	while (i >= start + 4) {
		out = `_${text.slice(i - 3, i)}${out}`;
		i -= 3;
	}
	return `${text.slice(0, i)}${out}`;
}

function received(value: number): string {
	const wholeAndLarge = value - value == 0 && value % 1 == 0 && (value > 4294967296 || value < -4294967296);
	return wholeAndLarge ? separated(`${value}`) : `${value}`;
}

function sizeOutOfRange(size: number): RangeError {
	return new RangeError(`The value of "size" is out of range. It must be >= 0 && <= ${kMaxLength}. Received ${received(size)}`);
}

@inline
export function allocSize(size: number): number {
	if (!(size >= 0 && size <= kMaxLength)) throw sizeOutOfRange(size);
	return size;
}

export class Buffer extends Uint8Array {
	constructor();
	constructor(length: number);
	constructor(source: Readonly<uint8[]>);
	constructor(buffer: ArrayBuffer);
	constructor(buffer: ArrayBuffer, byteOffset: number);
	constructor(buffer: ArrayBuffer, byteOffset: number, length: number);
	@inline
	constructor(source: number | Readonly<uint8[]> | ArrayBuffer = 0, byteOffset: number = 0, length: number = -1) {
		if (typeof source == "number") super(source);
		else if (source instanceof ArrayBuffer) {
			if (length < 0) super(source, byteOffset);
			else super(source, byteOffset, length);
		} else super(source);
	}

	static from(source: Readonly<Span<uint8>>): Buffer {
		const out = new Buffer(source.length);
		out.set(source);
		return out;
	}

	subarray(begin: number = 0, end: number = this.length): Buffer {
		const from = clampIndex(begin, this.length);
		const to = clampIndex(end, this.length);
		return new Buffer(this.buffer, this.byteOffset + from, to > from ? to - from : 0);
	}

	slice(begin: number = 0, end: number = this.length): Buffer {
		return this.subarray(begin, end);
	}

	toString(): string {
		return decodeUtf8(this);
	}

	toJSON(): BufferJson {
		const bytes: Readonly<Span<uint8>> = this;
		const data: number[] = [];
		for (let i = 0; i < bytes.length; i++) data.push(bytes[i]);
		return { type: "Buffer", data };
	}
}

function clampIndex(index: number, length: number): number {
	const whole = index < 0 ? Math.ceil(index) : Math.floor(index);
	if (whole < 0) return whole + length < 0 ? 0 : whole + length;
	return whole > length ? length : whole;
}
