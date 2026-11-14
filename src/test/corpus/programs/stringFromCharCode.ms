// String.fromCharCode takes any number of UTF-16 code units and keeps the low 16 bits of each, on every backend and at comptime.
// @stdout: A|Hi||A|Hi
// @stdout: é|x|é|true true false
const atCompile = @comptime { return String.fromCharCode(72, 105); };
const parts = [String.fromCharCode(65), String.fromCharCode(72, 105), String.fromCharCode(), String.fromCharCode(65601), atCompile];
console.log(parts.join("|"));
const text = "xé😀";
const x = String.fromCharCode(120);
console.log(`${String.fromCharCode(0xE9)}|${text.charAt(0)}|${text.charAt(1)}|${x == text.charAt(0)} ${x + "" == "x"} ${text.charAt(1) == "e"}`);
