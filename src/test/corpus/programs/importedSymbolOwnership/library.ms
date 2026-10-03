export function makeArr<T>(witness: T | null): T[] {
	const out: T[] = [];
	return out;
}

export class Multi {
	static one(): int32 { return 1 as int32; }
	static two(): int32 { return 2 as int32; }
}

export interface Headers { names: string[]; values: string[]; }
export function setHeader(headers: Headers, name: string, value: string): void {
	headers.names.push(name);
	headers.values.push(value);
}
