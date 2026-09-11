// std/meta — Metaprogramming API for macro authors
//
// Re-exports AST types from std/meta/node.ms (source of truth).
// Macro code runs at compile-time in the Raiser VM.
//
// Usage:
//   import { Node, NodeKind, createNode } from "std/meta";
//   import * as ast from "std/meta";

export * from "./node";
export * from "./decorator";

// Compile-time builtins (injected by the Raiser VM, macro bodies only)
extern function currentFile(): string;
extern function currentLine(): number;
extern function readFile(path: string): string;
extern function exec(cmd: string): string;
extern function error(msg: string, loc: SourceLocation): never;
extern function warning(msg: string, loc: SourceLocation): void;

// Node child access by index over the macro VM's flat wire — the Nim
// n[i]/n.len analog. Flat field names (n.object, n.left, ...) resolve only
// inside engine-mode checks, so a top-level helper shared between macros
// must traverse through these instead. Bridges live in
// src/compiler/meta/hostTable.ms.
extern function msNodeChildCount(n: Node): number;
extern function msNodeChildAt(n: Node, i: number): Node;

export function childCount(n: Node): number { return msNodeChildCount(n); }
export function childAt(n: Node, i: number): Node { return msNodeChildAt(n, i); }

// Literal values. Split by result type the way Nim splits intVal/floatVal: the
// Raiser picks typed opcodes (AddI64 vs AddF64) from the static type, so an
// accessor whose register kind varies with the input silently computes on the
// wrong field. Ask isFloatLiteral first — it answers what Nim reads off the node
// kind, which our representation folds into the literal's stored value.
extern function msNodeIsFloatLiteral(n: Node): boolean;
extern function msNodeIntValue(n: Node): int64;
extern function msNodeFloatValue(n: Node): float64;
extern function msNodeStringValue(n: Node): string;

export function isFloatLiteral(n: Node): boolean { return msNodeIsFloatLiteral(n); }
export function intValue(n: Node): int64 { return msNodeIntValue(n); }
export function floatValue(n: Node): float64 { return msNodeFloatValue(n); }
export function stringValue(n: Node): string { return msNodeStringValue(n); }

extern function msMetaBindSym(name: string): Node | null;
extern function msMetaGetType(n: Node, impl: boolean): Node | null;
extern function msMetaGetImpl(n: Node): Node | null;
extern function msMetaResolveType(text: string): Node | null;
extern function msMetaTypeKind(n: Node | null): int32;
extern function msMetaSameType(a: Node | null, b: Node | null): boolean;
extern function msMetaSymKind(n: Node | null): int32;

export function bindSym(name: string): Node | null { return msMetaBindSym(name); }
export function getType(n: Node | null): Node | null { if (n == null) return null; return msMetaGetType(n, false); }
export function getTypeImpl(n: Node | null): Node | null { if (n == null) return null; return msMetaGetType(n, true); }
export function getImpl(n: Node | null): Node | null { if (n == null) return null; return msMetaGetImpl(n); }
export function resolveType(text: string): Node | null { return msMetaResolveType(text); }
export function typeKind(n: Node | null): TypeKind { return msMetaTypeKind(n) as TypeKind; }
export function sameType(a: Node | null, b: Node | null): boolean { return msMetaSameType(a, b); }
export function symKind(n: Node | null): SymbolKind { return msMetaSymKind(n) as SymbolKind; }
