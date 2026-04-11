// std/compress — shared error + format types, used by inflate / deflate / zip.
//
// Pure MetaScript: no C extern, no @compile. Importing this file does NOT pull
// in any miniz source — each submodule (inflate.cms / deflate.cms / zip.cms)
// owns its own vendor imports so tree-shaking stays per-feature.

// Format selector — values mirrored in runtime/compress/inflate.h and deflate.h.
export enum CompressFormat {
	Gzip,     // = 0 — RFC 1952 gzip container (magic 1F 8B)
	Zlib,     // = 1 — RFC 1950 zlib container
	Deflate,  // = 2 — RFC 1951 raw DEFLATE
}

export enum CompressErrorKind {
	InvalidInput,
	Truncated,
	OutOfMemory,
	CompressionFailed,
	ZipError,
}

export interface CompressError {
	kind: CompressErrorKind;
	message: string;
}

export function compressError(kind: CompressErrorKind, msg: string): CompressError {
	return { kind: kind, message: msg };
}
