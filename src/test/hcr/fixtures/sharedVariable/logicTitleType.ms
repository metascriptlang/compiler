export const LIMIT: int32 = 9;
export const TITLE: int32 = 42;
export let counter: int32 = 5000;
export function bump(): int32 {
	counter += 1;
	return counter;
}
