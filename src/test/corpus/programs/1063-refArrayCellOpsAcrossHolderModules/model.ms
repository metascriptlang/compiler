export interface Texture { realloc: ((t: Texture) => void) | null; }
export struct Cell { texture: Texture | null; }
export struct Entry { texture: Texture | null; }

export interface Scene {
	cells: Vec<Cell>;
	entries: Map<string, Vec<Entry>>;
}

export function kids(this r: Scene): number { return 0; }
export function entryKids(this r: Scene): number { return 0; }
