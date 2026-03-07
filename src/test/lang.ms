// Language Tests Only — no compiler imports, C-backend safe
//
// Run: bun run-ms test src/test/lang.ms
//
// These tests exercise MetaScript language features using only
// std library imports. No compiler internals are pulled in,
// so this compiles cleanly to C.

import "./lang/basics";
import "./lang/strings";
import "./lang/types";
import "./lang/match";
import "./lang/controlFlow";
// Closure tests require C backend closure codegen fixes (env field typing, call casting)
// import "./lang/closures";
// import "./lang/closuresAdv";
import "./lang/interfaces";
import "./lang/classes";
import "./lang/result";
import "./lang/trycatch";
import "./lang/recursion";
// Advanced tests require std/process FFI (exec, readFile, writeFile)
// import "./lang/advanced";
import "./lang/async";
// syntax.ms requires: exponentiation lowering (** → pow), optional chain on value types, null coalescing on value types
// import "./lang/syntax";
