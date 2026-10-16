// String.fromCharCode takes any number of UTF-16 code units and keeps the low 16 bits of each, on every backend and at comptime.
// @stdout: A|Hi||A|Hi
const atCompile = @comptime { return String.fromCharCode(72, 105); };
const parts = [String.fromCharCode(65), String.fromCharCode(72, 105), String.fromCharCode(), String.fromCharCode(65601), atCompile];
console.log(parts.join("|"));
