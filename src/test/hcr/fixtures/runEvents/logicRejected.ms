let broken: int32 = fail();
function fail(): int32 {
	throw new Error("boom: edit rejected");
}
export function value(): string { return `9${broken}`; }
