import { parseJson } from "std/serialize/json/parser";
export function label(): string {
	return `${parseJson("[1]").ok}`;
}
