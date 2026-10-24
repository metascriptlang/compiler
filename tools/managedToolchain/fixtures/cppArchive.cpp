#include <stdexcept>
#include <vector>

extern "C" int cppArchiveSum(int count) {
    std::vector<int> values(count, 3);
    try {
        if (count < 0) throw std::out_of_range("count");
        int total = 0;
        for (int value : values) total += value;
        return total;
    } catch (const std::exception &) {
        return -1;
    }
}
