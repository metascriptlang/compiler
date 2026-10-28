#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
int main(){ auto v=std::make_unique<std::vector<std::string>>(); v->push_back("alloc");
 try{ throw std::runtime_error("boom"); }catch(const std::exception&e){ std::printf("cpp20 ok %s %s %zu\n",e.what(),v->at(0).c_str(),v->size()); return 0; }
 return 1; }
