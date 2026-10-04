export function toString<T>(this arr: T[]): string {
	let out = "";
	for (let i = 0; i < arr.length; i += 1) {
		if (i > 0) out += ",";
		const item = arr[i];
		if (item != null) out += `${item}`;
	}
	return out;
}
