// Guards bug226: a name on an enum type that is neither a member nor a static extension still reports "Property 'X' does not exist on type 'Mood'. Available: …".
// The enum type no longer reports it itself; the common missing-property diagnostic lists the enum members, so the text is the same.
import { compileToCWithStd } from "../helpers";

function enumError226(body: string): string {
	const result = compileToCWithStd(`
enum Mood226 { Calm, Angry }
function label(this mood: Mood226): uint8 { return (mood as int32) as uint8; }
function main(): int32 {
	const mood = Mood226.Angry;
	${body}
	return 0;
}
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug226: a name that is neither a member nor an extension keeps its diagnostic" {
	const want = "does not exist on type 'Mood226'. Available: Calm, Angry";
	assert enumError226("const m = Mood226.Bogus;").indexOf("Property 'Bogus' " + want, 0) >= 0;
	assert enumError226("const m = Mood226.bogus(1);").indexOf("Property 'bogus' " + want, 0) >= 0;
	assert enumError226("const n = mood.bogus();").indexOf("Property 'bogus' " + want, 0) >= 0;
}
