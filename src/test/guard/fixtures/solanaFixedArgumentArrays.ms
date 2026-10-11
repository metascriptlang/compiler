import { ProgramError, args, failWith, instruction, logU64 } from "std/solana";

import { FixedArrayInput, FixedArrayOp, ScalarArrayInput } from "./solanaFixedArgumentArrayTypes";

function decode(): Result<uint64, ProgramError> {
	const input = try args<FixedArrayInput>();
	let sum: uint64 = input.prefix ? 1 : 0;
	sum += (input.last ? 1000 : 0) as uint64;
	sum += input.empty.length as uint64;
	let weight: uint64 = 1;
	for (const byte of input.one) { sum += (byte as uint64) * weight; weight++; }
	for (const byte of input.four) { sum += (byte as uint64) * weight; weight++; }
	for (const byte of input.eight) { sum += (byte as uint64) * weight; weight++; }
	for (const byte of input.nearKey) { sum += (byte as uint64) * weight; weight++; }
	for (const byte of input.pastKey) { sum += (byte as uint64) * weight; weight++; }
	return Result.ok(sum);
}

function decodeScalar(): Result<uint64, ProgramError> {
	const x = try args<ScalarArrayInput>();
	if (x.u8[0] != 1 || x.u8[1] != 2 || x.u16[0] != 1 || x.u16[1] != 2 ||
		x.u32[0] != 1 || x.u32[1] != 2 || x.u64[0] != 1 || x.u64[1] != 2 ||
		x.i8[0] != -1 || x.i8[1] != 2 || x.i16[0] != -1 || x.i16[1] != 2 ||
		x.i32[0] != -1 || x.i32[1] != 2 || x.i64[0] != -1 || x.i64[1] != 2 ||
		!x.flags[0] || x.flags[1] || x.prefix != 5 || x.last != 7) {
		return Result.err(ProgramError.custom(99));
	}
	return Result.ok(29);
}

function dispatch(): Result<uint64, ProgramError> {
	const op = try instruction<FixedArrayOp>();
	return op == FixedArrayOp.Read ? decode() : decodeScalar();
}

function entry(): void {
	const result = dispatch();
	if (result.ok) { logU64(result.value); } else { failWith(result.error); }
}

entry();
