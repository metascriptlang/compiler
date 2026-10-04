// @stdout: receivers strings a,b numbers 1,2 fields c,d absent 2
// @exit: 0

function invoke(callback: () => void): void { callback(); }
let absent: int32 = 0;
function strings(values: string[] | null): void {
	invoke((): void => {
		if (values !== null) {
			if (!values.includes("a")) process.exit(1);
			values.push("b");
		} else absent += 1;
	});
}
function numbers(values: number[] | null): void {
	invoke((): void => {
		if (values !== null) {
			if (!values.includes(1)) process.exit(1);
			values.push(2);
		} else absent += 1;
	});
}
interface Holder { values: string[] | null; }
function field(holder: Holder): void {
	if (holder.values !== null) holder.values.push("d");
}
function verify(): void {
	const text: string[] = ["a"];
	const numeric: number[] = [1];
	const holder: Holder = { values: ["c"] };
	strings(text);
	numbers(numeric);
	strings(null);
	numbers(null);
	field(holder);
	if (text.length != 2 || text[0] != "a" || text[1] != "b") process.exit(1);
	if (numeric.length != 2 || numeric[0] != 1 || numeric[1] != 2) process.exit(1);
	if (holder.values === null) process.exit(1);
	console.log(`receivers strings ${text[0]},${text[1]} numbers ${numeric[0]},${numeric[1]} fields ${holder.values![0]},${holder.values![1]} absent ${absent}`);
}
verify();
