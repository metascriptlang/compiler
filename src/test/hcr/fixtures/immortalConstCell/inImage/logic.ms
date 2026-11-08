import { parseJson } from "std/serialize/json/parser";
function table(): uint32[] {
	const out: uint32[] = [];
	for (let i = 0; i < 4; i += 1) out.push(i as uint32);
	return out;
}
const TABLE: Readonly<uint32[]> = table();
export function label(): string {
	const parsed = parseJson("[1]");
	return `${TABLE[3]} ${parsed.ok}`;
}
