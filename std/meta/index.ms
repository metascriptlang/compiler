// std/meta — Metaprogramming API for macro authors
//
// Re-exports the compiler's own AST types via export *.
// Macro code runs at compile-time in the Raiser VM — these imports
// never reach codegen, so there is no circular dependency.
//
// Usage:
//   import { Node, NodeKind, createNode } from "std/meta";
//   import * as ast from "std/meta";

export * from "../../src/ast/node";

// Compile-time builtins (injected by the Raiser VM, macro bodies only)
extern function currentFile(): string;
extern function currentLine(): number;
extern function readFile(path: string): string;
extern function exec(cmd: string): string;
extern function error(msg: string, loc: SourceLocation): never;
extern function warning(msg: string, loc: SourceLocation): void;
