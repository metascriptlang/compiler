import { make } from "./box";

export function left(): string {
	const box = make<int32>(41);
	return box.value.toString() + ":" + box.version.toString();
}
