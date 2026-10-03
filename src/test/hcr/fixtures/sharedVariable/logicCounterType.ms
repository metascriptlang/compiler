export const LIMIT: int32 = 9;
export const TITLE: string = "two";
export let counter: int64 = 4000;
export function bump(): int32 {
	counter += 1;
	return counter as int32;
}
