@compile("./companion.cpp", "-std=c++20");

import { companionValue } from "./companion.h";

console.log(companionValue());
