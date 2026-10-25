// @stdout: a b 2
// note: a caller's type keeps its identity when a generic in another module instantiates a
// generic constructor with it, even when that module imports or declares a type of the same name.
import { engine, ownRows } from "./engine";

interface Row {
	id: string;
}

interface ListCell {
	id: string;
}

const rows = engine<Row>([{ id: "a" }]);
const cells = engine<ListCell>([{ id: "b" }]);
console.log(`${rows[0].id} ${cells[0].id} ${ownRows()}`);
