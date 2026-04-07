// cparse — MetaScript extern declaration emitter
// Walks the Obj list produced by parse.ms and emits MS source text
// (extern function, extern struct, extern enum, extern const, typedef).
//
// STATUS: skeleton. Implementation lands in task #19.
//
// This is the only net-new logic on top of the chibicc port — everything
// else is porting. Replaces src/module/cparse.ms string-based translator.

import { Obj } from "./obj";
import { CType, CTypeKind } from "./type";

export interface EmitOptions {
	withExport: boolean;        // prepend "export " to each decl?
	importedNames: string[];    // [] = emit all; otherwise whitelist by name
}

// Emit MS source text from the parsed top-level declarations.
//
// TODO(task #19):
//   - typedef → `type X = Y;` or `extern type X;`
//   - struct/union → `extern struct Name { field: MsType; ... }`
//   - enum → `extern enum Name { A = 1, B, ... }`
//   - function → `extern function name(p: T, ...): R;`
//   - variable → `extern const|let name: T;`
//   - importedNames filter
//   - stable ordering (match source order from Obj.file/line)
export function emitMetaScript(objs: Obj[], opts: EmitOptions): string {
	return "";
}

// Map a C type to a MetaScript type string. Moves the hand-coded table
// from src/module/cparse.ms cTypeToMs into a type-driven walker.
export function cTypeToMsType(t: CType): string {
	return match (t.kind) {
		CTypeKind.Void => "void",
		CTypeKind.Bool => "boolean",
		CTypeKind.Char => "uint8",
		CTypeKind.Short => "int16",
		CTypeKind.Int => "int32",
		CTypeKind.Long => "int64",
		CTypeKind.LongLong => "int64",
		CTypeKind.Float => "float32",
		CTypeKind.Double => "number",
		CTypeKind.LongDouble => "number",
		CTypeKind.Ptr => {
			if (t.base !== null && t.base.kind === CTypeKind.Void) return "unknown";
			return "unknown";  // TODO(#19): `Ptr<${cTypeToMsType(t.base)}>`
		},
		_ => "unknown",
	};
}
