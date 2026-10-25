export let extra: int32 = 100;
export let count: int32 = 1;
export let names: string[] = ["a"];
export function bump(): void {
	count += 1;
	names.push(`n${count}`);
}
