export struct Table {
	name: string;
	columns: Vec<string>;
	keyOf: Sendable<(id: uint32) => uint32>;
}

function table(name: string, keyOf: Sendable<(id: uint32) => uint32>): Table {
	return { name: name, columns: ["id"], keyOf: keyOf };
}

export const accounts: Readonly<Table> = table("accounts", (id: uint32): uint32 => id + 1);
