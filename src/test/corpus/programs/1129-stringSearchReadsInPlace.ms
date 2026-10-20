// @stdout: split 200000 M0.5 M199999.5 | split2 200000 M0.5 M199999.5 | count 199999 | replaceAll 999995 true | includes true false
const TOKENS = 200000;

let spaced = "";
let commas = "";
for (let at = 0; at < TOKENS; at++) {
	const token = "M" + at.toString() + ".5";
	spaced += (at === 0 ? "" : " ") + token;
	commas += (at === 0 ? "" : ", ") + token;
}

const parts = spaced.split(" ");
const parts2 = commas.split(", ");
const swapped = spaced.replaceAll(" ", "&nbsp;");

console.log("split", parts.length, parts[0], parts[parts.length - 1], "|",
	"split2", parts2.length, parts2[0], parts2[parts2.length - 1], "|",
	"count", spaced.count(" "), "|",
	"replaceAll", swapped.length - spaced.length, swapped.endsWith("&nbsp;M199999.5"), "|",
	"includes", spaced.includes("M199999.5"), spaced.includes("M200000."));
