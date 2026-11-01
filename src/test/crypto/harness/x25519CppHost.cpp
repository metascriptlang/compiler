#define main x25519FixtureMain
extern "C" {
#include "x25519TaintHost.c"
}
#undef main

int main(int argc, char **argv) {
	return x25519FixtureMain(argc, argv);
}
