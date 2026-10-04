@comptime export function digitSum(text: string): uint64 {
	let total: uint64 = 0;
	for (let i = 0; i < text.length; i++) { total = total * 58 + ((text.charCodeAt(i) - 49) as uint64); }
	return total;
}
export const SEED_TEXT = "2222";
export const PROGRAM: uint64 = digitSum(SEED_TEXT);
