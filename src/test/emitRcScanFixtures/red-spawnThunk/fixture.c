struct ModuleEmissionJob__fixture {
	Node__fixture* program;
};
struct dollarEnv_run_loop1___fixture {
	ModuleEmissionJob__fixture* job1;
};
void emitModuleJob__fixturecompileOms_u0(ModuleEmissionJob__fixture* job) {
	(void)job;
}
MS_LIB_PRIVATE void* dollarlifted_run_2___fixture_u0(void* _envP) {
ModuleEmissionJob__fixture* dollarborrow_0_;
{
  (dollarborrow_0_ = (*((dollarEnv_run_loop1___fixture*)_envP)).job1);
  msIncref(dollarborrow_0_);
  msDecref(dollarborrow_0_);
  return 0;
}
}
void run__fixture_u0(dollarEnv_run_loop1___fixture* dollarmove_7_) {
msClosure dollartmp_8_;
{
  (dollartmp_8_ = (msClosure){ .fn = (void*)dollarlifted_run_2___fixture_u0, .env = (void*)dollarmove_7_ });
  msSpawnHeldSubmit(dollarheld_2_, dollartmp_8_);
}
}
