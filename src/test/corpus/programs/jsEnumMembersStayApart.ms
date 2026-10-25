// @stdout: Red Green member Color_Red 5 7 blue
// note: the flat binding an enum member gets on JS (`Color_Red`) is not the public spelling of an author's own `Color_Red`; an exported const, a local const and an exported class spelled like members of an enum in the same module used to redeclare it (SyntaxError).
export enum Color { Red, Green, Blue }
export const Color_Red = "member Color_Red";
const Color_Green = 5;
export class Color_Blue {
	tag: string = "blue";
}
function localMember(): int32 {
	const Color_Green = 7;
	return Color_Green;
}
console.log(`${Color.Red} ${Color.Green} ${Color_Red} ${Color_Green} ${localMember()} ${new Color_Blue().tag}`);
