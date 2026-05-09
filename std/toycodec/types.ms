// ToyCodec — minimal codec proof using SERIALIZE A1+V2+A3 macro stack.
//
// Format: simple key:value, key:value text encoding. No spec compliance, no
// performance. Goal: prove that A1 (read type info), V2 (read decorators),
// A3 (work in generic functions) all compose correctly to build a real codec.
//
// Supported field types (V1): string, int32.
// Supported decorators (V1): @rename("alt").

export class ToyError {
	message: string;
}
