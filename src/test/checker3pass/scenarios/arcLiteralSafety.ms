import { checkOnly } from "../helpers";

test "contextual Arc literals preserve the constructor's deep-immutable pointee gate" {
	const result = checkOnly("class Cell { value: int32 = 0; }\nstruct SharedData { cell: Cell; }\nconst data: Arc<SharedData> = { cell: new Cell() };");
	assert result.errors.length > 0;
	assert result.errors.join("\n").contains("Arc<T> pointee must be deep-immutable data");
	assert result.errors.join("\n").contains("SharedData");
}
