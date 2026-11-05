# Language-level testing

Current `test`/`assert` syntax and power-assert meaning live in
[LANG.md](LANG.md#testing-framework). Test placement, discovery, focused verification and
remote execution belong to [src/test/CLAUDE.md](../src/test/CLAUDE.md) and
[TESTING.md](TESTING.md), not a parallel command list here.

Why language-level assertions? The compiler can inspect the assertion expression and expose
the operands of a failed comparison. A library call need not have that source structure.
Why group by file? A test's module already supplies a name and access to the implementation;
additional grouping syntax would duplicate that boundary.

The former `expect` keyword, “test bodies are not even parsed” claim and unimplemented runner
roadmap are retired. `git log -- docs/LANG-TEST.md` retains the design history. Do not infer
support, fail-fast details or runner options from that history; use the owning reference and
smallest real consumer when changing them.
