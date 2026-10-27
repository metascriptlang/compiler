// @stdout: 2 3 -1 7 0
// @stdout: 2 3 1 -1 5
// @stdout: 3 true false
const ASCII = @comptime {
	const s = "hello world";
	return `${s.indexOf("l")} ${s.lastIndexOf("l", 3)} ${s.indexOf("z")} ${s.indexOf("o", 5)} ${s.indexOf("")}`;
};
const WIDE = @comptime {
	const s = "héllo \u{1F600}x";
	return `${s.indexOf("l")} ${s.lastIndexOf("l")} ${s.indexOf("é")} ${s.indexOf("é", 2)} ${s.lastIndexOf(" ")}`;
};
const MIXED = @comptime {
	const s = "ab\u{1F600}cd";
	return `${s.indexOf("\u{1F600}") + 1} ${s.includes("cd")} ${s.includes("é")}`;
};
console.log(ASCII);
console.log(WIDE);
console.log(MIXED);
