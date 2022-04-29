#include <stdexcept>
#include <cstring>
#include <iostream>
#include <sstream>
#include <jni.h>
#include <string>
#include <android/log.h>

#include <opencv2/opencv.hpp>

#include "../../../../../native/src/native_api.h"

namespace {

JavaVM *java_vm = nullptr;
jmethodID jni_notify_method = nullptr;
jobject jni_service_instance = nullptr;
cv::Mat buffer_mat;

const char *sep = ", ";

void log_d(const std::string &text) {
    __android_log_write(ANDROID_LOG_DEBUG, "Android/Native",
                        "┌───────────────────────────────────────");
    __android_log_write(ANDROID_LOG_DEBUG, "Android/Native", ("│ " + text).c_str());
    __android_log_write(ANDROID_LOG_DEBUG, "Android/Native",
                        "└───────────────────────────────────────");
}

void log_d(const std::stringstream &stream) {
    log_d(stream.str());
}

std::string convertToStdString(JNIEnv *env, jstring str) {
    if (!str) {
        return "";
    }

    const auto string_class = env->GetObjectClass(str);
    const auto get_bytes_method = env->GetMethodID(string_class, "getBytes", "(Ljava/lang/String;)[B");
    const auto string_bytes = (jbyteArray) env->CallObjectMethod(str, get_bytes_method, env->NewStringUTF("UTF-8"));
    const auto length = (size_t) env->GetArrayLength(string_bytes);

    jbyte *bytes = env->GetByteArrayElements(string_bytes, nullptr);
    std::string result = std::string((char *) bytes, length);  // Create a wrapper, then copy.

    env->ReleaseByteArrayElements(string_bytes, bytes, JNI_ABORT);
    env->DeleteLocalRef(string_bytes);
    env->DeleteLocalRef(string_class);
    return result;
}

cv::Mat asMat(JNIEnv *env, jobject buffer, jint width, jint height, jint step) {
    auto *ptr = env->GetDirectBufferAddress(buffer);
    return cv::Mat(height, width, CV_8UC4, ptr, step);
}

JNIEnv *getJNIEnv() {
    JNIEnv *env;
    if (java_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK) {
        return env;
    }
    log_d(std::stringstream() << "AttachCurrentThread");
    if (java_vm->AttachCurrentThread(reinterpret_cast<JNIEnv **>(&env), nullptr) == JNI_OK) {
        return env;
    }
    throw std::runtime_error("Failed to attach JNI environment on");
}

void detachThread() {
    log_d(std::stringstream() << "DetachCurrentThread");
    if (java_vm->DetachCurrentThread() == JNI_OK) {
        return;
    }
    throw std::runtime_error("Failed to detach JNI environment on");
}

void callJavaFromCpp(const std::string &arg) {
    log_d(std::stringstream() << __FUNCTION__ << sep << arg);

    const auto env = getJNIEnv();
    if (jni_service_instance == nullptr) {
        throw std::runtime_error("Object instance not found");
    }

    log_d(std::stringstream() << env << sep << env->ExceptionCheck());

    jstring j_msg = env->NewStringUTF(arg.c_str());

    log_d(std::stringstream() << jni_service_instance << sep << j_msg);

    env->CallVoidMethod(jni_service_instance, jni_notify_method, j_msg);
}

}  // namespace

extern "C"
JNIEXPORT void JNICALL
Java_com_umasagashi_umasagashi_1app_ScreenCaptureService_initializeNativeCounterpart(
        JNIEnv *env, jobject thiz, jstring config) {
    log_d(std::stringstream() << __FUNCTION__ << sep << java_vm << sep << config);

    if (jni_service_instance == nullptr) {
        jni_service_instance = env->NewGlobalRef(thiz);
    }

    NativeApi::instance().setConfig(convertToStdString(env, config));
}

extern "C"
JNIEXPORT void JNICALL
Java_com_umasagashi_umasagashi_1app_ScreenCaptureService_updateNativeFrame(
        JNIEnv *env, jobject, jobject frame, jint width, jint height, jint row_stride,
        jint scaled_width, jint scaled_height) {
    log_d(std::stringstream() << __FUNCTION__ << sep << java_vm << sep << width << sep << height
                              << sep << scaled_width << sep << scaled_height << sep << row_stride);

    assert(jni_service_instance);

    auto raw_mat = asMat(env, frame, width, height, row_stride);

    const cv::Size scaled_size = {scaled_width, scaled_height};
    if (buffer_mat.size() != scaled_size) {
        buffer_mat = cv::Mat(scaled_size, CV_8UC4);
    }
    cv::resize(raw_mat, buffer_mat, scaled_size, 0, 0, cv::INTER_LINEAR);

    auto mat = cv::Mat(scaled_size, CV_8UC3);
    cv::cvtColor(buffer_mat, mat, cv::COLOR_RGBA2BGR);
    NativeApi::instance().updateFrame(mat);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_umasagashi_umasagashi_1app_ScreenCaptureService_startEventLoop(JNIEnv *, jobject) {
    log_d(std::stringstream() << __FUNCTION__);
    NativeApi::instance().startEventLoop();
}

extern "C"
JNIEXPORT void JNICALL
Java_com_umasagashi_umasagashi_1app_ScreenCaptureService_joinEventLoop(JNIEnv *, jobject) {
    log_d(std::stringstream() << __FUNCTION__);
    NativeApi::instance().joinEventLoop();
}

extern "C"
jint JNI_OnLoad(JavaVM *vm, void *) {
    java_vm = vm;
    JNIEnv *env = getJNIEnv();
    jclass jni_service_class = env->FindClass("com/umasagashi/umasagashi_app/ScreenCaptureService");
    jni_notify_method = env->GetMethodID(jni_service_class, "notifyPlatform", "(Ljava/lang/String;)V");

    log_d(std::stringstream() << __FUNCTION__ << sep << java_vm << sep << env << sep << jni_service_class
                              << sep << jni_notify_method << sep << env->ExceptionCheck());

    NativeApi::instance().setCallback(callJavaFromCpp);
    NativeApi::instance().setFinalizer(detachThread);

    return JNI_VERSION_1_6;
}
