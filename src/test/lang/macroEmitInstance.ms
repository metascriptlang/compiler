import { emitMarker, emitSpanMarker, viaMacro } from "./macroEmitFixture";

emitMarker("msEmitInstanceConcat");
emitSpanMarker("msEmitInstanceSpan");

test "a macro that returns an emit directive still expands after another macro expands inside a generic instance" {
	assert viaMacro<int32>(0) == 1;
}
