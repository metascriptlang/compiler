import { Discriminator } from "./discriminator";
import { Pubkey } from "./pubkey";

export enum BorshError {
	UnexpectedEnd,
	InvalidBool,
}

export struct BorshWriter {
	bytes: uint8[];
}

export struct BorshReader {
	bytes: uint8[];
	offset: int32;
}

export function create(this typeof BorshWriter): BorshWriter {
	return { bytes: [] };
}

export function of(this typeof BorshReader, bytes: uint8[]): BorshReader {
	return { bytes: bytes, offset: 0 };
}

function little(writer: BorshWriter, value: uint64, width: int32): BorshWriter {
	for (let i = 0; i < width; i++) {
		const shift: uint64 = (i * 8) as uint64;
		writer.bytes.push(((value >> shift) & 255) as uint8);
	}
	return writer;
}

export function discriminator(this writer: BorshWriter, tag: Discriminator): BorshWriter {
	for (let i = 0; i < 8; i++) { writer.bytes.push(tag.bytes[i]); }
	return writer;
}

export function u8(this writer: BorshWriter, value: uint8): BorshWriter {
	return little(writer, value as uint64, 1);
}

export function u16(this writer: BorshWriter, value: uint16): BorshWriter {
	return little(writer, value as uint64, 2);
}

export function u32(this writer: BorshWriter, value: uint32): BorshWriter {
	return little(writer, value as uint64, 4);
}

export function u64(this writer: BorshWriter, value: uint64): BorshWriter {
	return little(writer, value, 8);
}

export function i64(this writer: BorshWriter, value: int64): BorshWriter {
	return little(writer, value as uint64, 8);
}

export function bool(this writer: BorshWriter, value: boolean): BorshWriter {
	return little(writer, value ? 1 : 0, 1);
}

export function pubkey(this writer: BorshWriter, value: Pubkey): BorshWriter {
	for (let i = 0; i < 32; i++) { writer.bytes.push(value.bytes[i]); }
	return writer;
}

function read(this ref reader: BorshReader, width: int32): Result<uint64, BorshError> {
	if (reader.offset + width > reader.bytes.length) {
		return Result.err(BorshError.UnexpectedEnd);
	}
	let value: uint64 = 0;
	for (let i = width - 1; i >= 0; i--) {
		const byte: uint64 = reader.bytes[reader.offset + i] as uint64;
		value = (value << 8) | byte;
	}
	return Result.ok(value);
}

export function u8(this ref reader: BorshReader): Result<uint8, BorshError> {
	const value = try reader.read(1);
	reader.offset += 1;
	return Result.ok(value as uint8);
}

export function u16(this ref reader: BorshReader): Result<uint16, BorshError> {
	const value = try reader.read(2);
	reader.offset += 2;
	return Result.ok(value as uint16);
}

export function u32(this ref reader: BorshReader): Result<uint32, BorshError> {
	const value = try reader.read(4);
	reader.offset += 4;
	return Result.ok(value as uint32);
}

export function u64(this ref reader: BorshReader): Result<uint64, BorshError> {
	const value = try reader.read(8);
	reader.offset += 8;
	return Result.ok(value);
}

export function i64(this ref reader: BorshReader): Result<int64, BorshError> {
	const value = try reader.read(8);
	reader.offset += 8;
	return Result.ok(value as int64);
}

export function bool(this ref reader: BorshReader): Result<boolean, BorshError> {
	const value = try reader.read(1);
	if (value > 1) { return Result.err(BorshError.InvalidBool); }
	reader.offset += 1;
	return Result.ok(value == 1);
}

function keyAt(this ref reader: BorshReader): Result<Pubkey, BorshError> {
	if (reader.offset + 32 > reader.bytes.length) {
		return Result.err(BorshError.UnexpectedEnd);
	}
	let key = Pubkey.zero();
	for (let i = 0; i < 32; i++) { key.bytes[i] = reader.bytes[reader.offset + i]; }
	return Result.ok(key);
}

export function pubkey(this ref reader: BorshReader): Result<Pubkey, BorshError> {
	const key = try reader.keyAt();
	reader.offset += 32;
	return Result.ok(key);
}

test "a writer and a reader agree on Borsh's little-endian layout" {
	let key = Pubkey.zero();
	key.bytes[31] = 9;
	const writer = BorshWriter.create()
		.u8(7)
		.u16(0x1234)
		.u64(0x0102030405060708)
		.bool(true)
		.pubkey(key);
	assert writer.bytes.length == 1 + 2 + 8 + 1 + 32;
	assert writer.bytes[1] == 0x34 && writer.bytes[2] == 0x12 && writer.bytes[3] == 0x08;
	let reader = BorshReader.of(writer.bytes);
	const small = reader.u8();
	const middle = reader.u16();
	const wide = reader.u64();
	const flag = reader.bool();
	const back = reader.pubkey();
	assert small.ok && middle.ok && wide.ok && flag.ok && back.ok;
	if (small.ok && middle.ok && wide.ok && flag.ok && back.ok) {
		assert small.value == 7 && middle.value == 0x1234 && wide.value == 0x0102030405060708;
		assert flag.value && back.value == key;
	}
}

test "a reader refuses short input and a bool other than 0 or 1" {
	let short = BorshReader.of([1, 2, 3]);
	const wide = short.u64();
	assert !wide.ok;
	if (!wide.ok) { assert wide.error == BorshError.UnexpectedEnd; }
	let broken = BorshReader.of([2]);
	const flag = broken.bool();
	assert !flag.ok;
	if (!flag.ok) { assert flag.error == BorshError.InvalidBool; }
}
