import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf } from "./bytes";
import {
	argon2Problem, argon2Raw, argon2Encode, argon2VerifyEncoded,
	decodeArgon2id,
} from "./argon2";

export { CryptoError, CryptoErrorKind } from "../errors";

const DEFAULT_TIME_COST: int32 = 3;
const DEFAULT_MEMORY_COST: int32 = 65536;
const DEFAULT_PARALLELISM: int32 = 4;

export interface Argon2Limits {
	memoryCost: int32;
	timeCost: int32;
	parallelism: int32;
}

function freshDefaultLimits(): Argon2Limits {
	return {
		memoryCost: DEFAULT_MEMORY_COST * 4,
		timeCost: DEFAULT_TIME_COST * 4,
		parallelism: DEFAULT_PARALLELISM * 4,
	};
}

export const defaultArgon2Limits: Argon2Limits = freshDefaultLimits();

export function argon2HashSync(
	password: Bytes,
	saltBytes: Bytes,
	timeCost: int32 = DEFAULT_TIME_COST,
	memoryCost: int32 = DEFAULT_MEMORY_COST,
	parallelism: int32 = DEFAULT_PARALLELISM,
	hashLen: int32 = 32,
): Result<string, CryptoError> {
	const salt = bytesOf(saltBytes);
	const problem = argon2Problem(
		timeCost, memoryCost, parallelism, hashLen, salt.length,
	);
	if (problem != "") {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "argon2Hash", problem,
		));
	}
	const encoded = argon2Encode(
		bytesOf(password), salt, timeCost, memoryCost, parallelism, hashLen,
	);
	if (!encoded.ok) {
		return Result.err(cryptoError(
			CryptoErrorKind.HashFailed, "argon2Hash", "Argon2id hashing failed",
		));
	}
	return Result.ok(encoded.value);
}

export async function argon2Hash(
	password: Bytes,
	saltBytes: Bytes,
	timeCost: int32 = DEFAULT_TIME_COST,
	memoryCost: int32 = DEFAULT_MEMORY_COST,
	parallelism: int32 = DEFAULT_PARALLELISM,
	hashLen: int32 = 32,
): Promise<Result<string, CryptoError>> {
	return argon2HashSync(
		password, saltBytes, timeCost, memoryCost, parallelism, hashLen,
	);
}

export function argon2HashRawSync(
	password: Bytes,
	saltBytes: Bytes,
	timeCost: int32 = DEFAULT_TIME_COST,
	memoryCost: int32 = DEFAULT_MEMORY_COST,
	parallelism: int32 = DEFAULT_PARALLELISM,
	hashLen: int32 = 32,
): Result<Buffer, CryptoError> {
	const salt = bytesOf(saltBytes);
	const problem = argon2Problem(
		timeCost, memoryCost, parallelism, hashLen, salt.length,
	);
	if (problem != "") {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "argon2HashRaw", problem,
		));
	}
	const raw = argon2Raw(
		bytesOf(password), salt, timeCost, memoryCost, parallelism, hashLen,
	);
	if (!raw.ok) {
		return Result.err(cryptoError(
			CryptoErrorKind.HashFailed, "argon2HashRaw",
			"Argon2id raw hashing failed",
		));
	}
	return Result.ok(raw.value as Buffer);
}

export async function argon2HashRaw(
	password: Bytes,
	saltBytes: Bytes,
	timeCost: int32 = DEFAULT_TIME_COST,
	memoryCost: int32 = DEFAULT_MEMORY_COST,
	parallelism: int32 = DEFAULT_PARALLELISM,
	hashLen: int32 = 32,
): Promise<Result<Buffer, CryptoError>> {
	return argon2HashRawSync(
		password, saltBytes, timeCost, memoryCost, parallelism, hashLen,
	);
}

export function argon2VerifySync(
	encoded: string,
	password: Bytes,
	limits: Argon2Limits = freshDefaultLimits(),
): boolean {
	if (decodeArgon2id(encoded) == null) return false;
	return argon2VerifyEncoded(encoded, bytesOf(password), {
		memoryCost: limits.memoryCost,
		timeCost: limits.timeCost,
		parallelism: limits.parallelism,
	});
}

export async function argon2Verify(
	encoded: string,
	password: Bytes,
	limits: Argon2Limits = freshDefaultLimits(),
): Promise<boolean> {
	return argon2VerifySync(encoded, password, limits);
}
