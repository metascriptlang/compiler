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

struct AssertedFixture { name: string; id: int64; }

function assertedFixture(): AssertedFixture { return { name: "alice", id: 7 }; }

function refusedBy(f: () => void): boolean {
	try { f(); } catch { return true; }
	return false;
}

function holdsFor(f: () => boolean): boolean { return f(); }

test "assertionEvaluation: a callback inside an assertion destructures like one in a statement" {
	assert refusedBy(() => {
		const { name, id } = assertedFixture();
		if (name == "alice" && id == 7) throw new Error("expected refusal");
	});
	assert holdsFor(() => { const [a, b] = [3, 4]; return a + b == 7; });
	assert holdsFor(() => holdsFor(() => { const { id } = assertedFixture(); return id == 7; })), holdsFor(() => { const [m] = ["unused"]; return m == "unused"; }) ? "nested" : "message";
}
