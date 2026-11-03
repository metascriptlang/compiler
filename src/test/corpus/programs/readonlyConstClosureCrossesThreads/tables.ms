export struct Table {
	name: string;
	columns: Vec<string>;
	keyOf: Sendable<(id: uint32) => uint32>;
}

function table(name: string, keyOf: Sendable<(id: uint32) => uint32>): Table {
	return { name: name, columns: ["id"], keyOf: keyOf };
}

export const accounts: Readonly<Table> = table("accounts", (id: uint32): uint32 => id + 1);

export struct Account { id: string; balance: int64; }

export struct Rows<T> {
	name: string;
	keyOf: Sendable<(row: T) => string>;
}

function rows<T>(name: string, keyOf: Sendable<(row: T) => string>): Rows<T> {
	return { name: name, keyOf: keyOf };
}

export const ledger: Readonly<Rows<Account>> = rows<Account>("ledger", (row: Account): string => row.id);
