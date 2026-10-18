export enum Flavor { First, Second, Third }

@comptime export function pick(n: int32): Flavor {
	return n > 1 ? Flavor.Third : n > 0 ? Flavor.Second : Flavor.First;
}
