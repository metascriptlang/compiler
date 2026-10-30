import { Scene, kids, entryKids } from "./model";

export function touchCells(root: Scene): number {
	return root.kids();
}

export function touchEntries(root: Scene): number {
	return root.entryKids();
}
