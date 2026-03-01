# Testing — Language-Level Design

MetaScript has first-class testing support. Tests are a language construct, not a library — inspired by Zig and Rust. The compiler strips all test code from production builds (zero overhead).

## `test` Declaration (Language Keyword)

`test` is a top-level declaration keyword. Each test has a string name and a block body:

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
- In non-test builds (`msc run`, `msc build`), test blocks are **completely stripped** — never parsed into the AST
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

## `expect` — Global Assertion Function

`expect` is a compiler-recognized global function (like `console.log`). Available everywhere without import.

```ms
test "basic assertions" {
    expect(isValid(input));              // boolean check
    expect(result === 42);               // equality — shows both values on failure
    expect(name !== "");                  // inequality
    expect(list.length > 0);             // comparison
}
```

### Expression-Aware Failure Reporting

The compiler inspects the AST of the `expect()` argument. Binary comparisons (`===`, `!==`, `<`, `>`, `<=`, `>=`) capture both sides:

```
FAIL: 42 === 99           (numeric)
FAIL: "hello" === "world" (string)
FAIL: 3 > 10              (comparison)
```

Non-binary expressions get a generic message:
```
FAIL: expect failed
```

### `expect` Is Fatal (Fail-Fast)

Unlike the old `check()` (non-fatal), `expect` **stops the current test** on failure. The remaining tests in the file continue. This matches Zig (`try expect()` returns error) and Rust (`assert!` panics).

Rationale: fatal-first prevents cascading failures. If setup fails, you see one clear error instead of 20 downstream failures.

### `expect.eq` / `expect.ne` — Rich Equality (Pending)

For structured comparison with diff output:

```ms
test "parse result matches" {
    expect.eq(actual, expected);         // deep equality, shows diff on failure
    expect.ne(result, forbidden);        // deep inequality
}
```

**Status: PENDING** — requires runtime diff formatting. Start with `expect()` binary operator capture.

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

export function scanNumber(state: LexerState): void {
    // ... implementation
}

// Tests — stripped from production builds
test "isDigit" {
    expect(isDigit("0".code));
    expect(isDigit("5".code));
    expect(isDigit("9".code));
    expect(!isDigit("a".code));
    expect(!isDigit(" ".code));
}

test "isAlpha" {
    expect(isAlpha("a".code));
    expect(isAlpha("Z".code));
    expect(isAlpha("_".code));
    expect(!isAlpha("0".code));
}

test "scanNumber integer" {
    const s = createLexerState("42");
    scanNumber(s);
    expect(s.tokens.length === 1);
    expect(s.tokens[0].value === "42");
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

Compact: passing groups show count only. Failing tests expand with the failure message and **source location**.

---

## Pending Features

Features from Zig and Rust worth adopting. Each is independent — implement as needed.

### P1: Source Location on Failure

**Priority: HIGH** — The single most impactful missing feature.

Zig shows full stack traces. Rust shows file:line. MetaScript should show at minimum `file:line` on `expect` failure.

Implementation: the compiler knows the source location of every `expect()` call node. Emit it as a string literal argument to the runtime check function.

```
FAIL: 42 === 99  at src/checker/checkPass.ms:217
```

### P2: `skip` — Programmatic Test Skip

Zig: `return error.SkipZigTest`. Rust: `#[ignore]`.

```ms
test "requires network" {
    skip("no network in CI");
}
```

Or decorator form:
```ms
@skip("requires network")
test "fetch API" { ... }
```

Output: `test fetch API ... SKIP (requires network)`

Runner reports: `N passed  M failed  K skipped`

### P3: `expect.throws` — Error Expectation

Rust: `#[should_panic(expected = "...")]`. Zig: `expectError(err, val)`.

```ms
test "divide by zero" {
    expect.throws(() => divide(10, 0));
    expect.throws(() => divide(10, 0), "division by zero");  // message match
}
```

For Result types:
```ms
test "parse invalid input" {
    const result = parse("###");
    expect(!result.ok);
    expect(result.error === "unexpected token");
}
```

### P4: `expect.approx` — Floating-Point Tolerance

Zig: `expectApproxEqAbs`, `expectApproxEqRel`.

```ms
test "trigonometry" {
    expect.approx(sin(PI), 0.0, 1e-10);         // absolute tolerance
}
```

### P5: Test Filtering by File Pattern

Beyond `--filter "name"`, support file glob patterns:

```bash
msc test src/index.ms --filter "src/lexer/*"     # all lexer tests
msc test src/index.ms --filter "parse"            # name substring (existing)
```

### P6: Test Timeout

Prevent infinite loops from hanging the runner:

```ms
@timeout(5000)  // milliseconds
test "must complete quickly" { ... }
```

Default timeout: 30 seconds. Configurable via `--timeout` flag.

### P7: Parallel Execution

Rust runs tests in parallel by default (one thread per test). For MetaScript's C backend, this could use `fork()` or thread pool:

```bash
msc test src/index.ms --jobs 4        # 4 parallel workers
msc test src/index.ms --jobs 1        # sequential (default, current behavior)
```

**Requires**: test isolation (no shared mutable globals between tests).

### P8: `expect.eq` Deep Equality with Diff

Zig: `expectEqualStrings` shows side-by-side diff. Rust: `assert_eq!` shows both values.

For strings:
```
FAIL: expect.eq string mismatch
  expected: "hello world"
  actual:   "hello wrld"
                   ^
```

For arrays/objects: show first differing element with index.

### P9: Test-Only Code (`@test` Block)

Zig: `builtin.is_test`. Rust: `#[cfg(test)]`.

Helper functions that only exist in test builds:

```ms
@test function makeTestState(input: string): LexerState {
    // only compiled in test mode
    return createLexerState(input);
}

test "uses helper" {
    const s = makeTestState("42");
    // ...
}
```

### P10: Compile-Fail Tests

Zig: compile errors are caught at comptime. Rust: `compile_fail` doc tests.

```ms
@compileError
test "cannot add string and number" {
    const x: string = "hello" + 42;
}
```

Test passes if the code fails to type-check. Useful for testing the type checker itself.

---

## Implementation Phases

| Phase | Feature | Effort | Status |
|-------|---------|--------|--------|
| 1 | `test` keyword (parser + lexer) | Medium | **NEXT** |
| 2 | `expect` global function | Small | **NEXT** |
| 3 | Source location (P1) | Small | Pending |
| 4 | `skip` (P2) | Small | Pending |
| 5 | `expect.throws` (P3) | Medium | Pending |
| 6 | `expect.approx` (P4) | Small | Pending |
| 7 | File pattern filter (P5) | Small | Pending |
| 8 | Timeout (P6) | Medium | Pending |
| 9 | `expect.eq` diff (P8) | Medium | Pending |
| 10 | `@test` block (P9) | Small | Pending |
| 11 | Compile-fail tests (P10) | Large | Pending |
| 12 | Parallel execution (P7) | Large | Pending |

Phase 1-2 are the breaking change. Phases 3+ are incremental additions.

## Migration

Current `testGroup` + `test` + `check` pattern:
```ms
import { test, check, testGroup } from "std/testing";

testGroup("Lexer", () => {
    test("isDigit", () => {
        check(isDigit("0".code));
    });
});
```

New pattern:
```ms
// No import needed

test "isDigit" {
    expect(isDigit("0".code));
}
```

Migration is mechanical:
1. Remove `import { ... } from "std/testing"`
2. `testGroup("Name", () => { ... })` — unwrap, remove group wrapper
3. `test("name", () => { ... })` → `test "name" { ... }`
4. `check(...)` → `expect(...)`
5. `require(...)` → `expect(...)` (same behavior now — both fatal)
