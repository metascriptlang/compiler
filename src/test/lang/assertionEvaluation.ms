let messageCalls: int32 = 0;

function countedMessage(): string { messageCalls++; return "never built"; }

function heapMessage(): string { return "ab" + "c".repeat(2); }

test "assertionEvaluation: passing assertions suppress message evaluation for every expression shape" {
	messageCalls = 0;
	const local = heapMessage();
	assert local == "abcc", countedMessage();
	assert messageCalls == 0;
	assert local == "abcc", local;
	const check = (message: string): void => { assert message == "abcc", message; };
	check(heapMessage());
	assert local == "abcc", "got " + local;
	assert local == "abcc", heapMessage();
}

function heldMember(k: int32): int32 | string { return k > 0 ? 2 : "s"; }

function heldOrNull(k: int32): int32 | string | null { return k > 1 ? null : heldMember(k); }

function heldTextOrFlag(k: int32): string | boolean { return k > 0 ? "s" : true; }

test "assertionEvaluation: a message-less assertion over a union's text or equality runs its held arms" {
	assert `${heldMember(1)}` == "2";
	assert `${heldMember(1)}-${heldMember(0)}` == "2-s";
	assert `${heldOrNull(2)}` == "null";
	assert heldMember(0) == heldTextOrFlag(1);
	assert heldMember(1) != heldTextOrFlag(0);
}
