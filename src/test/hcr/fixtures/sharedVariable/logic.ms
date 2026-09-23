export const LIMIT: int32 = 5;
export let counter: int32 = 0;
export function bump(): int32 {
	counter += 1;
	return counter;
}
