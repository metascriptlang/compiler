/**
 * Sorts an array in place using a user-provided comparator function.
 * Stable insertion sort — O(n²) worst case but optimal for small arrays
 * (<64 elements). Generic over element type: works for any T[].
 * @param cmp Comparator returning negative if a < b, positive if a > b, zero if equal.
 */
export function sortBy<T>(this arr: T[], cmp: (a: T, b: T) => number): void {
	const n = arr.length;
	let i = 1;
	while (i < n) {
		const cur = arr[i];
		let j = i - 1;
		while (j >= 0 && cmp(arr[j], cur) > 0) {
			arr[j + 1] = arr[j];
			j = j - 1;
		}
		arr[j + 1] = cur;
		i = i + 1;
	}
}
