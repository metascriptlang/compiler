// bug058 — the assert MESSAGE expression was invisible to the compiler
//
// Symptom:    a name referenced only from `assert cond, msg` died at C compile
//             time — `call to undeclared function 'TypeKind_toString'` for an
//             enum toString, `use of undeclared identifier` for a module const.
//             Moving the same expression one line up (into its own statement)
//             compiled fine. Blocked 6 files of the src/test/index.ms gate.
// Root cause: `assertMessageExpr` was added to AssertStmtData in 743f446 but
//             three walkers were never taught the new field — forEachChild
//             (src/ast/visitor.ms), cloneNodeImpl (src/monomorphize/clone.ms)
//             and the checker (src/checker/checkPass.ms). Unchecked identifiers
//             got no resolvedSym (so codegen emitted the raw, unmangled name)
//             and reachability never marked the callee alive (so its decl was
//             dead-stripped while the call site survived).
// Fix:        all three now descend into assertMessageExpr. src/ast/
//             childTableGuard.ms pins the whole class: every Node-typed field
//             in std/meta/node.ms must be handled by every child table.

enum Bug058Kind {
	First,
	Second,
}

const BUG058_ONLY_IN_MESSAGE: string = "message-only";

function bug058Describe(): string {
	return "helper";
}

test "bug058: module const referenced only from an assert message survives" {
	assert 1 === 1, "const was stripped: " + BUG058_ONLY_IN_MESSAGE;
}

test "bug058: function called only from an assert message survives" {
	assert 1 === 1, "helper was stripped: " + bug058Describe();
}

test "bug058: enum toString called only from an assert message survives" {
	const k = Bug058Kind.Second;
	assert k === Bug058Kind.Second, "enum toString was stripped: " + k.toString();
}
