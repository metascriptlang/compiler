struct ModuleEmissionJob__fixture {
	Node__fixture* program;
};
void emitModuleJob__fixturecompileOms_u0(ModuleEmissionJob__fixture* job) {
	msIncrefCyclicRo((*job).program);
}
