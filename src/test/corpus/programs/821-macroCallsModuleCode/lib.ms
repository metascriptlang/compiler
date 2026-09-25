function twice(this s: string): string {
	return s + s;
}

export function doubled(x: number): string {
	return String(x).twice();
}

export function padded<T>(x: T): string {
	return String(x).padStart(3, "0");
}

export function doubledOf<T>(x: T): string {
	return String(x).twice();
}
