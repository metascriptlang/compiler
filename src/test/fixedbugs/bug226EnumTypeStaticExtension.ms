// Symptom: `Mood.fromByte(1)` failed with "Property 'fromByte' does not exist on type 'Mood'. Available: Calm, Angry".
// Root cause: a property read on the enum type itself was always taken as a member, so a name that is not a member never reached the static extensions.
// Fix: the enum type reads a member only when the name is one; any other name goes on to the static extensions, and the diagnostic for a name that is neither stays the same.
enum Mood226 { Calm, Angry }

function fromByte(this typeof Mood226, value: uint8): Mood226 { return (value as int32) as Mood226; }
function first(this typeof Mood226): Mood226 { return Mood226.Calm; }
function Calm(this typeof Mood226): int32 { return 7; }

test "bug226: a static extension on an enum type" {
	assert Mood226.fromByte(1) == Mood226.Angry;
	assert Mood226.first() == Mood226.Calm;
}

test "bug226: a member wins over a static extension of the same name" {
	assert (Mood226.Calm as int32) == 0;
}
