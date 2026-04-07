// cparse — Declaration parser
// Port of: ~/projects/chibicc parse.c (declaration-level subset only).
//
// STATUS: skeleton. Real implementation lands in task #17.
//
// We skip ~60% of chibicc's parse.c: function bodies, statement parsing, and
// most expression parsing. Only constant expressions are evaluated (for enum
// values and array sizes) — that logic lives in eval.ms.

import { Token } from "./token";
import { Obj } from "./obj";
import { Diagnostic } from "./error";
import { TargetInfo } from "./target";

export interface ParseResult {
	objs: Obj[];
	diagnostics: Diagnostic[];
}

// Parse a preprocessed token stream into a list of top-level declarations.
//
// TODO(task #17): port chibicc parse.c declaration machinery
//   - declspec() — storage class, qualifiers, type specifier
//   - declarator() — pointers, arrays, function types
//   - struct_decl, union_decl, enum_specifier
//   - typedef
//   - parameter lists (K&R + ANSI)
//   - bitfields, flexible array members
//   - SKIP: compound statements, expression statements, all of stmt.c
export function parseTranslationUnit(
	head: Token,
	target: TargetInfo
): ParseResult {
	return { objs: [], diagnostics: [] };
}
