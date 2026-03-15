// Crypto error types

export type CryptoErrorKind =
	| "InvalidAlgorithm"
	| "InvalidKey"
	| "InvalidInput"
	| "HashFailed"
	| "HmacFailed"
	| "RandomFailed"
	| "EncryptionFailed"
	| "DecryptionFailed"
	| "KeyDerivationFailed";

export interface CryptoError {
	kind: CryptoErrorKind;
	operation: string;
	message: string;
}

export function cryptoError(kind: CryptoErrorKind, operation: string, message: string): CryptoError {
	return { kind, operation, message };
}

export function InvalidAlgorithm(algorithm: string): CryptoError {
	return cryptoError("InvalidAlgorithm", algorithm, `Unsupported algorithm: ${algorithm}`);
}

export function InvalidKey(operation: string, reason: string): CryptoError {
	return cryptoError("InvalidKey", operation, `Invalid key: ${reason}`);
}

export function InvalidInput(operation: string, reason: string): CryptoError {
	return cryptoError("InvalidInput", operation, `Invalid input: ${reason}`);
}

export function HashFailed(algorithm: string, reason: string): CryptoError {
	return cryptoError("HashFailed", algorithm, `Hash failed: ${reason}`);
}

export function HmacFailed(algorithm: string, reason: string): CryptoError {
	return cryptoError("HmacFailed", algorithm, `HMAC failed: ${reason}`);
}

export function RandomFailed(reason: string): CryptoError {
	return cryptoError("RandomFailed", "random", `Random generation failed: ${reason}`);
}
