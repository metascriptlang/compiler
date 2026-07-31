// Helper for bug062 — exports an interface whose field is enum-typed plus a
// factory. The enum itself is deliberately NOT imported by the test file, so
// the enum reaches it only through the field's type.

export enum Grade { Poor, Fair, Good }

export interface Item {
	grade: Grade;
	label: string;
}

export function makeItem(): Item {
	return { grade: Grade.Good, label: "x" };
}
