export enum CryptoErrorKind {
	InvalidAlgorithm,
	InvalidKey,
	InvalidInput,
	InvalidEncoding,
	HashFailed,
	HmacFailed,
	RandomFailed,
	EncryptionFailed,
	DecryptionFailed,
	KeyDerivationFailed,
	AuthenticationFailed,
	KeyGenerationFailed,
	SignatureFailed,
	VerificationFailed,
	CertificateError,
	ConnectionFailed,
	HandshakeFailed,
}

export interface CryptoError {
	kind: CryptoErrorKind;
	operation: string;
	message: string;
}

export function cryptoError(kind: CryptoErrorKind, operation: string, message: string): CryptoError {
	return { kind, operation, message };
}

export function hashFailed(algorithm: string, reason: string): CryptoError {
	return cryptoError(CryptoErrorKind.HashFailed, `hash:${algorithm}`, reason);
}

export function hmacFailed(algorithm: string, reason: string): CryptoError {
	return cryptoError(CryptoErrorKind.HmacFailed, `hmac:${algorithm}`, reason);
}

export function randomFailed(reason: string): CryptoError {
	return cryptoError(CryptoErrorKind.RandomFailed, "random", reason);
}

export function invalidAlgorithm(algorithm: string): CryptoError {
	return cryptoError(CryptoErrorKind.InvalidAlgorithm, algorithm, "unsupported algorithm");
}

export function invalidKey(operation: string, reason: string): CryptoError {
	return cryptoError(CryptoErrorKind.InvalidKey, operation, reason);
}

export function invalidInput(operation: string, reason: string): CryptoError {
	return cryptoError(CryptoErrorKind.InvalidInput, operation, reason);
}

export function keyDerivationFailed(algorithm: string, reason: string): CryptoError {
	return cryptoError(CryptoErrorKind.KeyDerivationFailed, `kdf:${algorithm}`, reason);
}

export function isRetryable(e: CryptoError): boolean {
	return e.kind == CryptoErrorKind.RandomFailed;
}
