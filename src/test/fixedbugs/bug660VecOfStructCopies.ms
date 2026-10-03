// bug660 — a Vec of a struct with a managed field copies and drops
// Symptom: clang reports CellArrayWasMoved / CellArrayCopy as undeclared functions.
// Root cause: value-array lifetime calls spelled the element's bare name instead of the lifted operation.
// Fix: array operations are Symbols keyed by the canonical array Type, emitted once by their producer.

import { cellRounds, noteRounds } from "../corpus/programs/678-vecOfStructCopies/rounds";

test "bug660: a Vec of an imported struct copies and drops" {
	assert cellRounds(100) == 1580;
}

test "bug660: a Vec of a local struct copies and drops" {
	assert noteRounds(10) == 105;
}
