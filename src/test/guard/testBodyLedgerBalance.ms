// guard: test bodies get DRC injection — a value owned by a test body must be
// destroyed by the test binary with alloc==destroy on the DRC ledger, matching
// what the same statements get inside an ordinary function.
//
// INVARIANT: analyzeProgram routes TestDecl bodies through the same
//   function-body path as FunctionDecl (processTestDecl in analyzer/inject.ms).
//   The reference has no test node kind at all — injection keys on "a body
//   about to be emitted" (cgen.nim:1495/2749, exemptions only for generated
//   ops and inline iterators), so a body-carrying construct can never be
//   skipped there. Our processStmt enumerates node kinds with a silent
//   `_ => stmt` default; when TestDecl lost its arm the whole test lane ran
//   with different memory semantics than real programs (allocs lived,
//   destroys never ran) and lifecycle bugs were invisible to `msc test`.
//
// RED MEANS: a body-carrying construct lost its analyzer arm again (the
//   no-op-default class, NIM-REF row 88) — test-lane DRC regressed. The
//   [test] cell below reads the ledger of a real `msc test` binary run.
//
// GUARD-TEST-BALANCE GuardSinkCell

interface GuardSinkCell { v: int32; }

test "reassign owned refs inside a test body" {
	let p: GuardSinkCell = { v: 1 };
	p = { v: 2 };
	const q: GuardSinkCell = { v: 3 };
	assert p.v + q.v === 5;
}
