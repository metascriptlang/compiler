export type EncodingIndex = float64;
export const emptyEncoding = "";

const MAX_EXACT_ENCODING_LENGTH: int64 = 9007199254740991;

export function newEncodingOutput(length: int64): uint8[] {
	if (length < 0 || length > MAX_EXACT_ENCODING_LENGTH) {
		throw new RangeError("encoding output length exceeds exact array index range");
	}
	return new Array<uint8>(length as float64);
}

export function newDecodingOutput(length: int64): uint8[] {
	return newEncodingOutput(length);
}

export function freshEncodingOutputBytes(value: uint8[]): uint8[] {
	return value;
}

export function encodingOutputBytes(value: uint8[]): uint8[] {
	return value;
}
