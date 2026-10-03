export const LIMIT: int32 = 11;
export const TITLE: string = "three";
export let counter: int32 = 1234;
export function bump(): int32 {
	counter += 1;
	return counter;
}
