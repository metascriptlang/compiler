import { make, Stamp } from "./box";

export function right(): string {
	const integer = make<int32>(42);
	const text = make<string>("kept");
	const stamp = new Stamp<int32>();
	return integer.value.toString() + ":" + integer.version.toString() + " " + text.value + ":" + text.version.toString() + " stamp=" + stamp.count.toString();
}
