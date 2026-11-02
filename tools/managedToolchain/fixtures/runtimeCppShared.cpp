#include <cstdio>
#include <stdexcept>
#include <vector>

namespace {
int destroyed = 0;

struct Guard {
    ~Guard() { ++destroyed; }
};
}

extern "C" __attribute__((visibility("default"))) int cppSum(int count) {
    std::vector<int> values(count < 0 ? 0 : count, 2);
    try {
        Guard guard;
        if (count < 0) throw std::out_of_range("count");
        int total = 0;
        for (int value : values) total += value;
        return total;
    } catch (const std::exception &error) {
        std::printf("cpp caught=%s destroyed=%d\n", error.what(), destroyed);
        return -1;
    }
}

extern "C" __attribute__((visibility("default"))) int cppDestroyed(void) {
    return destroyed;
}
