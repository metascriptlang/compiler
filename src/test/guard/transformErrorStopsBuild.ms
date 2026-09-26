// nim-guard: an error a transform pass reports stops the build at its line.
//
// Nim: every phase reports through localError(conf, info, ...) (msgs.nim:648);
// the duplicate case label is semtypes.nim:715, at the label's info.
//
// RED MEANS a transform error went to a list nobody reads again: the build
// carries on and C fails later in the C compiler (or JS accepts it silently).
//
// GUARD-JS
// GUARD-CHECK-FAIL match: duplicate case label
// GUARD-CHECK-FAIL transformErrorStopsBuild.ms:18:

enum Color { Red, Green, Blue }

function name(c: Color, g: boolean): string {
	return match (c) {
		Color.Red | Color.Green => "rg",
		Color.Red when g => "r",
		_ => "other",
	};
}

console.log(name(Color.Red, true));
console.log("GUARD-OK");
