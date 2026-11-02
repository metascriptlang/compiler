export enum BoundaryKind {
	Bool,
	I8,
	I16,
	I32,
	U8,
	U16,
	U32,
	I64,
	U64,
	F32,
	F64,
	Void,
	Callback,
	String,
	Struct,
	Vec,
	Span,
	Handle,
}

export function unwiredKind(kind: BoundaryKind, what: string): never {
	const name = BoundaryKind[kind];
	throw new Error(`internal: boundary kind ${name} has no ${what}`);
}

export interface ScalarRange {
	low: string;
	high: string;
}

export interface ScalarFacts {
	msType: string;
	letter: string;
	jsType: string;
	range: ScalarRange | null;
	typedArray: string;
	jsZero: string;
}

export function scalarFacts(kind: BoundaryKind, what: string): ScalarFacts {
	return match (kind) {
		BoundaryKind.Bool => ({
			msType: "boolean",
			letter: "i",
			jsType: "boolean",
			range: null,
			typedArray: "Uint8Array",
			jsZero: "0",
		}),
		BoundaryKind.I8 => ({
			msType: "int8",
			letter: "i",
			jsType: "number",
			range: { low: "-128", high: "127" },
			typedArray: "Int8Array",
			jsZero: "0",
		}),
		BoundaryKind.I16 => ({
			msType: "int16",
			letter: "i",
			jsType: "number",
			range: { low: "-32768", high: "32767" },
			typedArray: "Int16Array",
			jsZero: "0",
		}),
		BoundaryKind.I32 => ({
			msType: "int32",
			letter: "i",
			jsType: "number",
			range: { low: "-2147483648", high: "2147483647" },
			typedArray: "Int32Array",
			jsZero: "0",
		}),
		BoundaryKind.U8 => ({
			msType: "uint8",
			letter: "i",
			jsType: "number",
			range: { low: "0", high: "255" },
			typedArray: "Uint8Array",
			jsZero: "0",
		}),
		BoundaryKind.U16 => ({
			msType: "uint16",
			letter: "i",
			jsType: "number",
			range: { low: "0", high: "65535" },
			typedArray: "Uint16Array",
			jsZero: "0",
		}),
		BoundaryKind.U32 => ({
			msType: "uint32",
			letter: "i",
			jsType: "number",
			range: { low: "0", high: "4294967295" },
			typedArray: "Uint32Array",
			jsZero: "0",
		}),
		BoundaryKind.I64 => ({
			msType: "int64",
			letter: "j",
			jsType: "bigint",
			range: {
				low: "-9223372036854775808n",
				high: "9223372036854775807n",
			},
			typedArray: "BigInt64Array",
			jsZero: "0n",
		}),
		BoundaryKind.U64 => ({
			msType: "uint64",
			letter: "j",
			jsType: "bigint",
			range: { low: "0n", high: "18446744073709551615n" },
			typedArray: "BigUint64Array",
			jsZero: "0n",
		}),
		BoundaryKind.F32 => ({
			msType: "float32",
			letter: "f",
			jsType: "number",
			range: null,
			typedArray: "Float32Array",
			jsZero: "0",
		}),
		BoundaryKind.F64 => ({
			msType: "float64",
			letter: "d",
			jsType: "number",
			range: null,
			typedArray: "Float64Array",
			jsZero: "0",
		}),
		BoundaryKind.Void
			| BoundaryKind.Callback
			| BoundaryKind.String
			| BoundaryKind.Struct
			| BoundaryKind.Vec
			| BoundaryKind.Span
			| BoundaryKind.Handle => { unwiredKind(kind, what); },
	};
}

export function signatureLetter(kind: BoundaryKind): string {
	return match (kind) {
		BoundaryKind.Void => "v",
		BoundaryKind.String => "s",
		BoundaryKind.Span => "p",
		_ => scalarFacts(kind, "callback signature letter").letter,
	};
}

export function msTypeOf(kind: BoundaryKind): string {
	if (kind == BoundaryKind.Void) return "void";
	return scalarFacts(kind, "scalar type").msType;
}
