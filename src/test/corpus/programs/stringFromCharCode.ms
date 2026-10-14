// @stdout: fromCharCode A true A ,
// @exit: 0

function charOf(code: int32): string {
	return String.fromCharCode(code);
}

const ascii = String.fromCharCode(65);
const bmp = charOf(9731) == "☃";
const masked = charOf(65601);
const comma = String.fromCharCode(64 + 1 - 21);
console.log("fromCharCode " + ascii + " " + bmp + " " + masked + " " + comma);
