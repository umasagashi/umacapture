#include <sole/sole.hpp>

#include "uuid_util.h"

std::string uuid::uuid4() {
    return std::string(sole::uuid4().str());
}
