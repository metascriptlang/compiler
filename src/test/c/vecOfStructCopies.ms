import { cellRounds, noteRounds } from "../corpus/programs/678-vecOfStructCopies/rounds";

test "vecOfStructCopies: a Vec of an imported struct copies and drops" {
	assert cellRounds(100) == 1580;
}

test "vecOfStructCopies: a Vec of a local struct copies and drops" {
	assert noteRounds(10) == 105;
}
