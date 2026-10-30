export function touch<T>(root: T): number {
	return root.kids();
}
