#pragma once

#include "chara_detail/chara_detail_record.h"

namespace uma::chara_detail {

struct RecordInfo {
    std::string record_id;
    std::optional<record::RecordType> record_type;
};

}  // namespace uma::chara_detail
