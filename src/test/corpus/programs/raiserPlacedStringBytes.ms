// @stdout: 12 3.5 true false 2 12
let text = "12";
function run(): string {
	let total = 0;
	for (let i = 0; i < 3; i++) total += text.parseInt() as int32;
	const grown = "ab" + text;
	return (total / 3).toString() + " " + "3.5".parseFloat().toString() + " " + grown.startsWith("ab").toString()
		+ " " + grown.startsWith("ba").toString() + " " + grown.indexOf("12").toString() + " " + ("  12 ".trim()).toString();
}
console.log(run());
