import { Gauge as GaugeA } from "./fixtures/staticReceiverA";
import { Gauge as GaugeB } from "./fixtures/staticReceiverB";

test "a static extension binds to the type its receiver names" {
	assert GaugeA.make() == 11;
	assert GaugeB.make() == 22;
}

test "prelude statics keep resolving through their own types" {
	assert Math.floor(3.7) == 3.0;
	assert Number.isInteger(5);
}
