export const LIMIT: int32 = 5;
export const TITLE: string = "one";
export let counter: int32 = 1;
export function bump(): int32 {
	counter += 1;
	return counter;
}
