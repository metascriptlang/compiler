// Symptom: `mood.label()` on an enum value failed with "Property 'label' does not exist on type 'Mood'. Available: Calm, Angry".
// Root cause: checkMemberExpr rewrote every property on an enum-typed object into a member access, so the extension lookup was never reached.
// Fix: the member rewrite applies only when the property is a member or the receiver is the enum type itself, as Nim's tryReadingTypeField tyEnum arm returns nil for a non-member.
import { Stance207, cost } from "./bug207helper";

enum Mood207 { Calm, Angry }

struct Pet207 { mood: Mood207; hunger: int32; }

function label(this mood: Mood207): uint8 {
	return (mood as int32) as uint8;
}

function scaled(this mood: Mood207, factor: int32): int32 {
	return ((mood as int32) + 1) * factor;
}

function labelOf207(mood: Mood207): uint8 {
	return mood.label();
}

test "bug207: extension on an enum local and an enum literal" {
	const mood = Mood207.Angry;
	assert mood.label() == 1;
	assert Mood207.Angry.label() == 1;
	assert Mood207.Calm.label() == 0;
}

test "bug207: extension on an enum parameter and a struct field" {
	const pet: Pet207 = { mood: Mood207.Angry, hunger: 3 };
	assert labelOf207(Mood207.Calm) == 0;
	assert pet.mood.label() == 1;
	assert pet.mood.scaled(5) == 10;
}

test "bug207: extension on an imported enum" {
	const stance = Stance207.Rest;
	assert stance.cost(10) == 12;
	assert Stance207.Strike.cost(1) == 2;
}
