#include <sole/sole.hpp>

#include "uuid_util.h"

std::string uuid::uuid4() {
    return sole::uuid4().str();
}
