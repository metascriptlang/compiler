export enum Grade { Poor, Fair, Good }

export interface Item {
	grade: Grade;
	label: string;
}

export function makeItem(): Item {
	return { grade: Grade.Good, label: "x" };
}
