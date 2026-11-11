#include <array>
#include <span>
#include <stdexcept>
#include <string>

struct ThreadTally {
	int count = 0;
	~ThreadTally() { count = -1; }
};
static thread_local ThreadTally tally;

static int deep(int depth) {
	if (depth == 0) throw std::runtime_error("matrix");
	return deep(depth - 1) + 1;
}

extern "C" int matrixCppValue(void) {
	std::array<int, 3> values{10, 14, 18};
	std::span<const int> view(values);
	try {
		return deep(5);
	} catch (const std::runtime_error &error) {
		tally.count += 1;
		return view[0] + view[1] + view[2] + (int)std::string(error.what()).size() + tally.count - 1;
	}
}
