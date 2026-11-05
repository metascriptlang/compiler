// TextEncoder and TextDecoder: UTF-8, the one encoding the Encoding Standard requires, on every
// backend alike; the decode kernel is the backend's own (utf8.*).

import { Uint8Array } from "./core";
import { wellFormedPrefix } from "../string/utf8Repair";
import { decodeUtf8 } from "./utf8";

const UTF8_LABELS = ["unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8"];
const NO_BYTES: uint8[] = [];

export interface TextDecoderOptions {
	fatal?: boolean;
	ignoreBOM?: boolean;
}

export interface TextDecodeOptions {
	stream?: boolean;
}

export class TextEncoder {
	readonly encoding: string = "utf-8";

	// A lone surrogate, which a string holds in its three-byte WTF-8 form, encodes as U+FFFD.
	encode(input: string = ""): Uint8Array {
		const bytes = input.asBytes();
		const out = new Uint8Array(bytes.length);
		const into: Span<uint8> = out;
		let i = 0;
		while (i < bytes.length) {
			if (bytes[i] == 0xED && i + 2 < bytes.length && bytes[i + 1] >= 0xA0) {
				into[i] = 0xEF;
				into[i + 1] = 0xBF;
				into[i + 2] = 0xBD;
				i += 3;
			} else {
				into[i] = bytes[i];
				i += 1;
			}
		}
		return out;
	}
}

export class TextDecoder {
	readonly encoding: string = "utf-8";
	readonly fatal: boolean;
	readonly ignoreBOM: boolean;

	constructor(label: string = "utf-8", options: TextDecoderOptions = {}) {
		if (!UTF8_LABELS.includes(label.trim().toLowerCase())) throw new RangeError(`The "${label}" encoding is not supported`);
		this.fatal = options.fatal ?? false;
		this.ignoreBOM = options.ignoreBOM ?? false;
	}

	decode(input: Readonly<Span<uint8>> = NO_BYTES, options: TextDecodeOptions = {}): string {
		if (options.stream ?? false) throw new TypeError("TextDecoder streaming is not supported");
		const skip = !this.ignoreBOM && input.length >= 3 && input[0] == 0xEF && input[1] == 0xBB && input[2] == 0xBF ? 3 : 0;
		const text = input[skip .. input.length];
		if (this.fatal && wellFormedPrefix(text, 0, false) != text.length) throw new TypeError("The encoded data was not valid for encoding utf-8");
		return decodeUtf8(text);
	}
}
