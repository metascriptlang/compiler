// GUARD-OS bare
// GUARD-ASAN
// A bare build defaults to DRC: an object that leaves scope runs its onDestroy and its block returns to
// the bare heap. RED MEANS the bare default is manual again, or bare DRC never releases a scope's object.
let destroyed: int32 = 0;

class Token {
	value: int32 = 7;
}

function onDestroy(this token: Token): void {
	destroyed += token.value;
}

function readToken(): int32 {
	const token = new Token();
	return token.value;
}

const read = readToken();
if (read == 7 && destroyed == 7) console.log("GUARD-OK");
