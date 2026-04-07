# cparse fixtures

Real and hand-written C headers used as acceptance tests for the cparse
module. A fixture "passes" when:

1. `parseHeader()` returns zero diagnostics of severity Error.
2. The emitted MS source compiles through the main compiler.
3. Every symbol named in that fixture's `EXPECTED_SYMBOLS` (see `test.ms`)
   appears in the emitted output.

## Progression

Work through these in order when porting chibicc phases. Each one stresses
more of the pipeline.

| Fixture              | What it exercises                                       |
|----------------------|---------------------------------------------------------|
| `minimal.h`          | Everything we claim to support in v1 — hand-written     |
| `stdint_mini.h`      | Just fixed-width integer typedefs                       |
| `stdio_mini.h`       | FILE* opaque type, varargs, function pointer callbacks  |
| `pthread_mini.h`     | Opaque handles, complex function pointer types          |
| `sqlite3_mini.h`     | Real-world amalgamation stress test (~200 functions)    |

`_mini` suffix means a reduced subset of the real header kept in-tree so
tests don't depend on the host's system headers. The full headers are
exercised by CLI tests that run against `/usr/include/...` on CI.

## Adding a fixture

1. Drop the `.h` file here.
2. Add an entry in `test.ms` under the `// acceptance tests` section:
   ```metascript
   test "fixture: your_header.h" {
       const source = readFixture("your_header.h");
       const out = parseHeader(source, "your_header.h", defaultOptions());
       assertNoErrors(out.diagnostics);
       assertContains(out.msSource, "expected_symbol_1");
       assertContains(out.msSource, "expected_symbol_2");
   }
   ```
3. Run `bun run test-ms src/compiler/cparse/test.ms`.
