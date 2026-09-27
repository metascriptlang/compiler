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
