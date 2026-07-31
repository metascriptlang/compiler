// bug066 — asBytes on an rvalue receiver failed to compile on C
//
// Symptom:    `const rv = (a + b).asBytes();` — clang: "cannot take the
//             address of an rvalue of type 'msString'". Measured in audit1
//             (BUGS.md §2 zero-copy bridge ownership row, hole (a)).
//
// Root cause: the zero-copy bridge emits `((msUint8Array*)&(receiver))` — the
//             receiver must be addressable — but rvalueLower only materialized
//             rvalue receivers in ExprStmt position. A VariableDecl
//             initializer kept the raw rvalue (here the lowered
//             msStringConcat call) under the `&`.
//
// Fix:        rvalueLower gains a walkExpandBlocks VariableDecl branch gated
//             on builtinKind === "AsBytes": hoist the receiver into a peer
//             temp statement (NIM-REF row 49 — receiver→temp in rvalueLower
//             is the sanctioned home; flat splice, no scope-stealing block).
//               const rv = (a + b).asBytes();
//                 →  const $rval = a + b; const rv = $rval.asBytes();

function bug066Joined(): string {
	const a = "he";
	const b = "llo";
	return a + b;
}

test "bug066: asBytes on a concat rvalue receiver" {
	const rv = (bug066Joined() + "!").asBytes();
	assert rv.length === 6;
	assert rv[0] === 104;
	assert rv[5] === 33;
}

test "bug066: asBytes on a direct call rvalue receiver" {
	const direct = bug066Joined().asBytes();
	assert direct.length === 5;
	assert direct[4] === 111;
}

test "bug066: statement-position rvalue receiver still works" {
	(bug066Joined() + "?").asBytes();
	assert bug066Joined().length === 5;
}
