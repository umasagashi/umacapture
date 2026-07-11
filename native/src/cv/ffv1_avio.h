#pragma once

#include <filesystem>
#include <fstream>
#include <stdexcept>

extern "C" {
#include <libavformat/avio.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
}

namespace uma::video::ffv1_detail {

// Bridges an AVIOContext to a std::fstream opened on the wide std::filesystem::path, so ffmpeg's I/O goes
// through the same non-ASCII-safe path handling the rest of the codebase uses for images
// (Frame::save/decodeBgr, frame.h). The matroska muxer seeks back to patch its header/cues at trailer
// time, so the write stream is opened in|out (seekable), not append-only. One instance is either a reader
// or a writer; it owns the AVIOContext, which the caller assigns to AVFormatContext::pb.
class FileAvio {
public:
    FileAvio(const std::filesystem::path &path, bool write)
        : write_(write) {
        const auto base = std::ios::binary;
        if (write_) {
            std::filesystem::create_directories(path.parent_path().empty() ? "." : path.parent_path());
            file_.open(path, base | std::ios::in | std::ios::out | std::ios::trunc);
        } else {
            file_.open(path, base | std::ios::in);
        }
        if (!file_) {
            throw std::runtime_error("FileAvio: failed to open: " + path.generic_string());
        }
        constexpr int buffer_size = 1 << 16;
        auto *buffer = static_cast<unsigned char *>(av_malloc(buffer_size));
        if (buffer == nullptr) {
            throw std::runtime_error("FileAvio: av_malloc failed");
        }
        ctx_ = avio_alloc_context(
            buffer,
            buffer_size,
            write_ ? 1 : 0,
            this,
            write_ ? nullptr : &FileAvio::readPacket,
            write_ ? &FileAvio::writePacket : nullptr,
            &FileAvio::seek);
        if (ctx_ == nullptr) {
            av_free(buffer);
            throw std::runtime_error("FileAvio: avio_alloc_context failed");
        }
    }

    ~FileAvio() {
        if (ctx_ != nullptr) {
            // The buffer may have been reallocated internally; free the current one, then the context.
            av_freep(&ctx_->buffer);
            avio_context_free(&ctx_);
        }
    }

    FileAvio(const FileAvio &) = delete;
    FileAvio &operator=(const FileAvio &) = delete;

    [[nodiscard]] AVIOContext *context() const { return ctx_; }

private:
    static int readPacket(void *opaque, uint8_t *buf, int buf_size) {
        auto *self = static_cast<FileAvio *>(opaque);
        self->file_.read(reinterpret_cast<char *>(buf), buf_size);
        const auto count = static_cast<int>(self->file_.gcount());
        if (count == 0) {
            return AVERROR_EOF;
        }
        // A partial read sets failbit alongside eofbit; clear it so subsequent seeks/reads still work.
        self->file_.clear();
        return count;
    }

    static int writePacket(void *opaque, const uint8_t *buf, int buf_size) {
        auto *self = static_cast<FileAvio *>(opaque);
        self->file_.write(reinterpret_cast<const char *>(buf), buf_size);
        if (!self->file_) {
            return AVERROR(EIO);
        }
        return buf_size;
    }

    static int64_t seek(void *opaque, int64_t offset, int whence) {
        auto *self = static_cast<FileAvio *>(opaque);
        if (whence & AVSEEK_SIZE) {
            return self->size();
        }
        const std::ios_base::seekdir dir = (whence == SEEK_CUR) ? std::ios::cur
                                         : (whence == SEEK_END) ? std::ios::end
                                                                : std::ios::beg;
        self->file_.clear();
        if (self->write_) {
            self->file_.seekp(offset, dir);
            return static_cast<int64_t>(self->file_.tellp());
        }
        self->file_.seekg(offset, dir);
        return static_cast<int64_t>(self->file_.tellg());
    }

    int64_t size() {
        file_.clear();
        if (write_) {
            const auto cur = file_.tellp();
            file_.seekp(0, std::ios::end);
            const auto end = file_.tellp();
            file_.seekp(cur);
            return static_cast<int64_t>(end);
        }
        const auto cur = file_.tellg();
        file_.seekg(0, std::ios::end);
        const auto end = file_.tellg();
        file_.seekg(cur);
        return static_cast<int64_t>(end);
    }

    const bool write_;
    std::fstream file_;
    AVIOContext *ctx_ = nullptr;
};

}  // namespace uma::video::ffv1_detail
