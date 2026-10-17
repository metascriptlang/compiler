// An echoed JsonValue prints through the Json formatter; the formatter is chosen by the
// declaration the value's type names, so a type that merely spells the same name is not one.

import { compileToCWithStd, compileToCWithStdModules } from "../helpers";

test "echoing a JsonValue prints it as Json" {
	const src = `
function main(): void {
	const pr = parseJson("{\\"s\\":1}");
	if (!pr.ok) return;
	const v: JsonValue = pr.value;
	console.log(v);
}
main();
`;
	const r = compileToCWithStd(src);
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.indexOf("\\033[35mJson ") >= 0;
	assert r.value.indexOf("<JsonValueData>") < 0;
}

test "a union named like JsonValueData is not echoed as Json" {
	const src = `
enum Tone { Warm, Cool }
type JsonValueData = match (tone: Tone) { Tone.Warm => { heat: int32 }, Tone.Cool => { chill: int32 } };
function main(): void {
	const v: JsonValueData = { tone: Tone.Warm, heat: 3 };
	console.log(v);
}
main();
`;
	const r = compileToCWithStdModules(src);
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.indexOf("\\033[35mJson ") < 0;
}
