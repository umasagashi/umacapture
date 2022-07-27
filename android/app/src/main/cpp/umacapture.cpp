#include <cstring>
#include <iostream>
#include <jni.h>
#include <sstream>
#include <stdexcept>
#include <string>

#include <android/log.h>

#include <opencv2/opencv.hpp>

#include "util/logger_util.h"
#include "core/native_api.h"

namespace uma::android {

class JavaVMInstance {
public:
    void setVM(JavaVM *v) {
        assert_(vm == nullptr);
        vm = v;
        JNIEnv *e = env();
        jclass service_class = e->FindClass("com/umasagashi/umacapture/ScreenCaptureService");
        notify_method = e->GetMethodID(service_class, "notifyPlatform", "(Ljava/lang/String;)V");
    }

    void setServiceInstance(jobject thiz) {
        if (service_instance == nullptr) {
            service_instance = env()->NewGlobalRef(thiz);
        }
    }

    void detachThisThread() const {
        assert_(vm != nullptr);
        env();  // Ensure this thread attached.
        const int result = vm->DetachCurrentThread();
        vlog_debug(result);
        if (result == JNI_OK) {
            return;
        }

        log_fatal("Failed to detach JNI environment");
        throw std::runtime_error("Failed to detach JNI environment");
    }

    void notifyPlatform(const std::string &arg) {
        assert_(notify_method != nullptr);
        assert_(service_instance != nullptr);
        JNIEnv *e = env();
        jstring j_arg = e->NewStringUTF(arg.c_str());
        e->CallVoidMethod(service_instance, notify_method, j_arg);
        e->DeleteLocalRef(j_arg);
    }

    [[nodiscard]] std::string newStdString(jstring str) const {
        if (!str) {
            return "";
        }

        JNIEnv *e = env();
        const auto string_class = e->GetObjectClass(str);
        const auto get_bytes_method = e->GetMethodID(string_class, "getBytes", "(Ljava/lang/String;)[B");
        const auto string_bytes = (jbyteArray) e->CallObjectMethod(str, get_bytes_method, e->NewStringUTF("UTF-8"));
        const auto length = (size_t) e->GetArrayLength(string_bytes);

        jbyte *bytes = e->GetByteArrayElements(string_bytes, nullptr);
        std::string result = std::string((char *) bytes, length);  // Create a wrapper, then copy.

        e->ReleaseByteArrayElements(string_bytes, bytes, JNI_ABORT);
        e->DeleteLocalRef(string_bytes);
        e->DeleteLocalRef(string_class);
        return result;
    }

    [[maybe_unused]] cv::Mat wrapAsMat(jobject buffer, jint width, jint height, jint step) const {
        auto *ptr = env()->GetDirectBufferAddress(buffer);
        return {height, width, CV_8UC4, ptr, step};
    }

private:
    [[nodiscard]] JNIEnv *env() const {
        JNIEnv *e;
        e = getAttachedEnv();
        if (e != nullptr) {
            return e;
        }

        e = attachAndGetEnv();
        if (e != nullptr) {
            return e;
        }

        log_fatal("Failed to attach JNI environment");
        throw std::runtime_error("Failed to attach JNI environment");
    }

    [[nodiscard]] JNIEnv *getAttachedEnv() const {
        assert_(vm != nullptr);

        JNIEnv *e;
        const int result = vm->GetEnv(reinterpret_cast<void **>(&e), JNI_VERSION_1_6);
        vlog_trace(result);
        return (result == JNI_OK) ? e : nullptr;
    }

    [[nodiscard]] JNIEnv *attachAndGetEnv() const {
        assert_(vm != nullptr);

        JNIEnv *e;
        const int result = vm->AttachCurrentThread(reinterpret_cast<JNIEnv **>(&e), nullptr);
        vlog_debug(result);
        return (result == JNI_OK) ? e : nullptr;
    }

    JavaVM *vm = nullptr;
    jmethodID notify_method = nullptr;
    jobject service_instance = nullptr;
};

inline JavaVMInstance java_vm;

}  // namespace

extern "C" {

jint JNI_OnLoad(JavaVM *vm, void *) {
    uma::logger_util::init();

    log_debug("");

    vlog_trace(1, 2, 3);
    vlog_debug(1, 2, 3);
    vlog_info(1, 2, 3);
    vlog_warning(1, 2, 3);
    vlog_error(1, 2, 3);
    vlog_fatal(1, 2, 3);

    uma::android::java_vm.setVM(vm);
    uma::app::NativeApi::instance().setDetachCallback([&]() { uma::android::java_vm.detachThisThread(); });
    uma::app::NativeApi::instance().setNotifyCallback(
            [&](const auto &arg) { uma::android::java_vm.notifyPlatform(arg); });
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL
Java_com_umasagashi_umacapture_ScreenCaptureService_startEventLoop(JNIEnv *, jobject thiz, jstring config) {
    log_debug("");
    uma::android::java_vm.setServiceInstance(thiz);
    uma::app::NativeApi::instance().startEventLoop(uma::android::java_vm.newStdString(config));

}

JNIEXPORT void JNICALL Java_com_umasagashi_umacapture_ScreenCaptureService_joinEventLoop(JNIEnv *, jobject) {
    log_debug("");
    uma::app::NativeApi::instance().joinEventLoop();
}

JNIEXPORT jboolean JNICALL
Java_com_umasagashi_umacapture_ScreenCaptureService_isRunning(JNIEnv *, jobject) {
    return uma::app::NativeApi::instance().isRunning();
}

JNIEXPORT void JNICALL Java_com_umasagashi_umacapture_ScreenCaptureService_updateNativeFrame(
        JNIEnv *,
        jobject,
        jobject frame,
        jint width,
        jint height,
        jint row_stride,
        jint scaled_width,
        jint scaled_height) {
    static cv::Mat buffer_mat;

    log_trace("");

    auto raw_mat = uma::android::java_vm.wrapAsMat(frame, width, height, row_stride);

    const cv::Size scaled_size = {scaled_width, scaled_height};
    if (buffer_mat.size() != scaled_size) {
        buffer_mat = cv::Mat(scaled_size, CV_8UC4);
    }
    cv::resize(raw_mat, buffer_mat, scaled_size, 0, 0, cv::INTER_LINEAR);

    auto mat = cv::Mat(scaled_size, CV_8UC3);
    cv::cvtColor(buffer_mat, mat, cv::COLOR_RGBA2BGR);
    uma::app::NativeApi::instance().updateFrame(mat,
                                                uma::chrono_util::timestamp());  // TODO: take timestamp in android.
}

JNIEXPORT void JNICALL
Java_com_umasagashi_umacapture_ScreenCaptureService_notifyCaptureStarted(JNIEnv *, jobject) {
    log_debug("");
    uma::app::NativeApi::instance().notifyCaptureStarted();
}

JNIEXPORT void JNICALL
Java_com_umasagashi_umacapture_ScreenCaptureService_notifyCaptureStopped(JNIEnv *, jobject) {
    log_debug("");
    uma::app::NativeApi::instance().notifyCaptureStopped();
}

}  // extern "C"
