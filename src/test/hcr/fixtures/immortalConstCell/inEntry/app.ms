import { label } from "./logic";
function table(): uint32[] {
	const out: uint32[] = [];
	for (let i = 0; i < 4; i += 1) out.push(i as uint32);
	return out;
}
const TABLE: Readonly<uint32[]> = table();
console.log(`HCR-ICC ${TABLE[3]} ${label()}`);
