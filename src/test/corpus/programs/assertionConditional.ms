type List<T> = T[];

let reads: int32 = 0;

function next(): boolean {
	reads += 1;
	return true;
}

const on: boolean = true;
const off: boolean = false;
const text: string = "ready";
const empty: string = "";
const values: List<int32> = [1];
const missing: List<int32> | null = null;
const yes = on as boolean ? 1 : 2;
const no = off as boolean ? 1 : 2;
const present = text as string ? "ready" : "empty";
const absent = empty as string ? "ready" : "empty";
const element = values as List<int32> ? values[0] : 0;
const nothing = missing as (List<int32> | null) ? 1 : 0;
const negative = off ? 1 : on as boolean ? -2 : 3;
const nested = on ? off as boolean ? 1 : 2 : 3;
const once = next() as boolean ? reads : 0;
const result = `${yes} ${no}|${present} ${absent}|${element} ${nothing}|` +
	`${negative} ${nested}|${once}`;
if (result != "1 2|ready empty|1 0|-2 2|1") {
	throw new Error("assertion consumed its conditional delimiter");
}
console.log(result);
