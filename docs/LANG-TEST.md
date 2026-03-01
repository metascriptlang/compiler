# Testing — Language-Level Design

MetaScript has first-class testing built into the language. `test` and `expect` are **keywords** — no imports, no library, no `std/testing`. The compiler strips all test code from production builds (zero overhead).

Inspired by Zig (`test "name" { }`) and Rust (`#[test]`), but simpler than Nim (which uses templates/macros to fake keyword syntax).

## `test` Keyword

`test` is a top-level declaration. Each test has a string name and a block body:

```ms
test "isDigit recognizes digits" {
    expect(isDigit("0".code));
    expect(isDigit("9".code));
    expect(!isDigit("a".code));
}

test "tokenize empty string" {
    const tokens = lex("");
    expect(tokens.length === 0);
}
```

Rules:
- `test` is **top-level only** — cannot appear inside functions, classes, or other tests
- The name is a **string literal** (allows spaces, punctuation, any description)
- The body is a block `{ ... }` with access to all module-scope declarations (including private)
- In non-test builds (`msc run`, `msc build`), test blocks are **completely stripped** — not even parsed
- In test builds (`msc test`), test blocks are collected and executed by the generated test runner

### No `testGroup` — File Is the Group

There is no grouping construct. The **file name** serves as the group:

```
 src/lexer/scanner.ms (12)
   isDigit recognizes digits .............. ok
   isDigit rejects letters ................ ok
   scanNumber handles integers ............ ok
   ...

 src/parser/expressions/core.ms (8)
   binary expression precedence ........... ok
   ...
```

This matches Zig (flat `test` blocks, no nesting) and Rust (`mod tests` = one level). Grouping by file is natural — tests sit next to the code they test.

## `expect` Keyword

`expect` is a statement keyword (like `return`, `throw`). Available everywhere inside `test` blocks without import.

```ms
test "basic assertions" {
    expect isValid(input);                // boolean check
    expect result === 42;                 // equality — shows both values on failure
    expect name !== "";                   // inequality
    expect list.length > 0;              // comparison
}
```

Parentheses are optional (keyword syntax), but allowed for grouping:

```ms
expect a === b;                // no parens
expect(a === b);               // parens OK — groups the expression
expect (a + b) === (c + d);   // parens for sub-expressions
```

### Expression-Aware Failure Reporting

The compiler inspects the AST of the `expect` expression. Binary comparisons (`===`, `!==`, `<`, `>`, `<=`, `>=`) capture both sides:

```
FAIL: 42 === 99           at scanner.ms:45
FAIL: "hello" === "world" at scanner.ms:46
FAIL: 3 > 10              at scanner.ms:47
```

Non-binary expressions get the source text:
```
FAIL: isValid(input)       at scanner.ms:48
```

### `expect` Is Fatal (Fail-Fast)

`expect` **stops the current test** on first failure. The remaining tests in the file continue. This matches Zig (`try expect()` returns error) and Rust (`assert!` panics).

Rationale: fatal-first prevents cascading failures. If setup fails, you see one clear error instead of 20 downstream failures.

## Complete Example

```ms
// src/lexer/scanner.ms

export function isDigit(ch: number): boolean {
    return ch >= "0".code && ch <= "9".code;
}

export function isAlpha(ch: number): boolean {
    return (ch >= "a".code && ch <= "z".code)
        || (ch >= "A".code && ch <= "Z".code)
        || ch === "_".code;
}

// Tests — stripped from production builds, zero overhead
test "isDigit" {
    expect isDigit("0".code);
    expect isDigit("5".code);
    expect isDigit("9".code);
    expect !isDigit("a".code);
    expect !isDigit(" ".code);
}

test "isAlpha" {
    expect isAlpha("a".code);
    expect isAlpha("Z".code);
    expect isAlpha("_".code);
    expect !isAlpha("0".code);
}

test "scanNumber integer" {
    const s = createLexerState("42");
    scanNumber(s);
    expect s.tokens.length === 1;
    expect s.tokens[0].value === "42";
}
```

## Test Runner

```bash
# Run all tests (entry point's full import graph)
msc test src/index.ms

# Run specific file's tests
msc test src/lexer/scanner.ms

# Filter by test name (substring match)
msc test src/index.ms --filter "isDigit"
```

Output format:
```
 src/lexer/scanner.ms (3)
 src/lexer/lexer.ms (5)
 src/parser/expressions/core.ms (8)
   binary precedence with parentheses ... FAIL
     FAIL: 3 === 7  at core.ms:412

 16 passed  1 failed
```

Compact: passing groups show count only. Failing tests expand with the failure message and source location.

## Grammar

```
TestDecl     = "test" StringLiteral Block
ExpectStmt   = "expect" Expression ";"
```

Both are keywords in the lexer (`TokenKind.Test`, `TokenKind.Expect`). `test` is parsed at the top-level statement position (alongside `function`, `class`, `interface`). `expect` is parsed at the statement position (alongside `return`, `throw`).

## Comparison with Other Languages

| | MetaScript | Zig | Rust | Nim |
|---|---|---|---|---|
| `test` | **keyword** | **keyword** | `#[test]` attribute | template (library) |
| `expect`/assert | **keyword** | `try expect()` (library fn) | `assert!` (macro) | `check` (macro) |
| Import needed | **no** | `@import("std").testing` | no | `import unittest` |
| Grouping | file = group | file = group | `mod tests` | `suite "name":` |
| Stripping | automatic (not parsed) | automatic (not compiled) | `#[cfg(test)]` | manual (`when defined`) |
| Failure info | AST capture + source loc | stack trace | panic + file:line | macro AST rewrite |

MetaScript is the only language where BOTH test declaration AND assertion are keywords. This is the simplest possible design — zero imports, zero library, zero macros.

---

## Implementation

### Phase 1: Keywords (Reference Compiler)

The reference compiler (Zig) must learn these keywords first (chicken-and-egg: it compiles .ms files).

**Lexer** (`lexer.zig`):
- Add `Test`, `Expect` to TokenKind enum
- Add `"test"`, `"expect"` to keyword map

**Parser** (`parser.zig`):
- `test`: at top-level, parse `Test StringLiteral Block` → TestDecl node
- `expect`: at statement position, parse `Expect Expression Semicolon` → ExpectStmt node

**AST** (`node.zig`):
- Add `TestDecl` NodeKind with `{ name: string, body: Node }`
- Add `ExpectStmt` NodeKind with `{ expr: Node }`

**Codegen** (`cgen.zig`):
- `TestDecl`: register test entry (reuse existing `emitTestDecl` infrastructure)
- `ExpectStmt`: emit assertion (reuse existing `emitCheckAssert` with source location)
- Non-test mode: strip both completely

**Estimated**: ~150 lines across 4 Zig files. The existing test infrastructure (`test_entries`, `emitTestDecl`, `emitCheckAssert`, `ms_test_run_all`) is reused — only the frontend changes.

### Phase 2: Keywords (Self-Hosted Compiler)

Once the reference compiler supports the keywords, the self-hosted compiler can:
1. Add `Test`, `Expect` to `TokenKind` in `token.ms`
2. Parse `TestDecl` and `ExpectStmt` in the parser
3. Handle in checker (type-check test body, validate expect expression)
4. Emit in C codegen (same infrastructure as reference compiler)

**Estimated**: ~200 lines across 6 .ms files.

### Phase 3: Migration

Mechanical transformation of all 111 .ms files:
1. Remove `import { test, check, testGroup } from "std/testing"`
2. Unwrap `testGroup("Name", () => { ... })` — remove group wrapper
3. `test("name", () => { ... })` → `test "name" { ... }`
4. `check(expr)` → `expect expr;`
5. `require(expr)` → `expect expr;`

---

## Pending Features

Features from Zig/Rust worth adopting later. Each is independent.

### P1: Source Location on Failure

**Priority: HIGH** — included in base implementation.

The compiler knows the source location of every `expect` node. Emit file:line as a string literal in the generated assertion code.

```
FAIL: 42 === 99  at src/checker/checkPass.ms:217
```

### P2: `skip` Keyword

Zig: `return error.SkipZigTest`. Rust: `#[ignore]`.

```ms
test "requires network" {
    skip "no network in CI";
}
```

A statement keyword (like `expect`). Immediately exits the test with SKIPPED status.

Runner reports: `N passed  M failed  K skipped`

### P3: `expect.throws` / Error Expectation

Rust: `#[should_panic(expected = "...")]`. Zig: `expectError(err, val)`.

Two possible designs:

**Option A — decorator on test block:**
```ms
@throws("division by zero")
test "divide by zero" {
    divide(10, 0);
}
```

**Option B — expect variant:**
```ms
test "divide by zero" {
    expect throws divide(10, 0);           // any error
    expect throws("division by zero") divide(10, 0);  // message match
}
```

For Result types, regular `expect` already works:
```ms
test "parse invalid input" {
    const result = parse("###");
    expect !result.ok;
    expect result.error === "unexpected token";
}
```

### P4: `expect.approx` — Floating-Point Tolerance

Zig: `expectApproxEqAbs`, `expectApproxEqRel`.

```ms
test "trigonometry" {
    expect approx(sin(PI), 0.0, 1e-10);
}
```

Could be a keyword modifier (`expect approx`) or a builtin function.

### P5: Test Filtering by File Pattern

Beyond `--filter "name"`, support file glob patterns:

```bash
msc test src/index.ms --filter "src/lexer/*"     # all lexer tests
msc test src/index.ms --filter "parse"            # name substring
```

### P6: Test Timeout

Prevent infinite loops from hanging the runner:

```ms
@timeout(5000)
test "must complete quickly" { ... }
```

Default timeout: 30 seconds. Configurable via `--timeout` flag.

### P7: Parallel Execution

Rust runs tests in parallel by default. For MetaScript's C backend:

```bash
msc test src/index.ms --jobs 4        # 4 parallel workers
msc test src/index.ms --jobs 1        # sequential (default)
```

Requires test isolation (no shared mutable globals between tests).

### P8: Deep Equality with Diff

Zig: `expectEqualStrings` shows side-by-side diff. Rust: `assert_eq!` shows both values.

For strings:
```
FAIL: string mismatch at parser.ms:42
  expected: "hello world"
  actual:   "hello wrld"
                   ^
```

For arrays/objects: show first differing element with index.

### P9: Test-Only Code

Zig: `builtin.is_test`. Rust: `#[cfg(test)]`.

Helper functions that only exist in test builds:

```ms
@test function makeTestState(input: string): LexerState {
    return createLexerState(input);
}

test "uses helper" {
    const s = makeTestState("42");
}
```

The `@test` decorator strips the function from non-test builds.

### P10: Compile-Fail Tests

Zig: compile errors are caught at comptime. Rust: `compile_fail` doc tests.

```ms
@compileError
test "cannot add string and number" {
    const x: string = "hello" + 42;
}
```

Test passes if the code fails to type-check.

---

## Implementation Priority

| Phase | Feature | Effort | Status |
|-------|---------|--------|--------|
| 1 | `test` + `expect` keywords (ref compiler) | ~150 lines Zig | **NEXT** |
| 2 | `test` + `expect` keywords (self-hosted) | ~200 lines MS | **NEXT** |
| 3 | Migration (111 files) | Mechanical | After Phase 1-2 |
| 4 | Source location P1 | Small | Part of Phase 1-2 |
| 5 | `skip` keyword P2 | Small | Pending |
| 6 | Error expectation P3 | Medium | Pending |
| 7 | Float tolerance P4 | Small | Pending |
| 8 | File filter P5 | Small | Pending |
| 9 | Timeout P6 | Medium | Pending |
| 10 | Deep equality P8 | Medium | Pending |
| 11 | `@test` decorator P9 | Small | Pending |
| 12 | Compile-fail P10 | Large | Pending |
| 13 | Parallel P7 | Large | Pending |

## Migration Path

```ms
// OLD — library functions, requires import
import { test, check, testGroup } from "std/testing";

testGroup("Lexer", () => {
    test("isDigit", () => {
        check(isDigit("0".code));
        check(!isDigit("a".code));
    });
});

// NEW — language keywords, no import
test "isDigit" {
    expect isDigit("0".code);
    expect !isDigit("a".code);
}
```
