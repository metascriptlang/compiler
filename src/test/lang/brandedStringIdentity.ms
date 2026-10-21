type EntityId = string & { __brand: "EntityId" };
type EntityAlias = string & { __brand: "EntityId" };

function text(value: string): string { return value; }
function entity(value: EntityId): string { return value as string; }
function differ(a: EntityId, b: EntityId): boolean { return a !== b; }

test "branded strings: aliases share identity while operations use the base representation" {
	for (const value of ["", "k", "entity:seven"]) {
		const id = value as EntityId;
		const alias = value as EntityAlias;
		assert text(id) == value;
		assert entity(alias) == value;
		assert id.length == value.length;
		assert id == alias;
	}
}

test "branded strings: inequality compares the base strings" {
	for (const value of ["", "k", "entity:seven"]) {
		const id = value as EntityId;
		const other = (value + "!") as EntityId;
		assert id != other;
		assert !(id != (value as EntityAlias));
		assert differ(id, other);
		assert !differ(id, value as EntityId);
	}
}
