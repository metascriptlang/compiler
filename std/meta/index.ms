// std/meta — Metaprogramming API for macro authors
//
// Re-exports AST types from std/meta/node.ms (source of truth).
// Macro code runs at compile-time in the Raiser VM.
//
// Usage:
//   import { Node, NodeKind, createNode } from "std/meta";
//   import * as ast from "std/meta";

export * from "./node";

// Compile-time builtins (injected by the Raiser VM, macro bodies only)
extern function currentFile(): string;
extern function currentLine(): number;
extern function readFile(path: string): string;
extern function exec(cmd: string): string;
extern function error(msg: string, loc: SourceLocation): never;
extern function warning(msg: string, loc: SourceLocation): void;
