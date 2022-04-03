#include <stdexcept>
#include <cstring>
#include <iostream>
#include <sstream>
#include <jni.h>
#include <string>
#include <android/log.h>

#include "../../../../../native/src/App.h"

namespace {
    JavaVM *javaVm = nullptr;
    jclass jniCls = nullptr;
    jmethodID jniMethod = nullptr;
    jobject jniObj = nullptr;
}

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

std::string jstring2string(JNIEnv *env, jstring jStr) {
    if (!jStr)
        return "";

    const auto stringClass = env->GetObjectClass(jStr);
    const auto getBytes = env->GetMethodID(stringClass, "getBytes", "(Ljava/lang/String;)[B");
    const auto stringJbytes = (jbyteArray) env->CallObjectMethod(jStr, getBytes,
                                                                 env->NewStringUTF("UTF-8"));

    auto length = (size_t) env->GetArrayLength(stringJbytes);
    jbyte *pBytes = env->GetByteArrayElements(stringJbytes, nullptr);

    std::string ret = std::string((char *) pBytes, length);
    env->ReleaseByteArrayElements(stringJbytes, pBytes, JNI_ABORT);

    env->DeleteLocalRef(stringJbytes);
    env->DeleteLocalRef(stringClass);
    return ret;
}

JNIEnv *getJNIEnv() {
    JNIEnv *env;
    if (javaVm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK) {
        return env;
    }
    log_d(std::stringstream() << "AttachCurrentThread");
    if (javaVm->AttachCurrentThread(reinterpret_cast<JNIEnv **>(&env), nullptr) == JNI_OK) {
        return env;
    }
    throw std::runtime_error("Failed to attach JNI environment on");
}

void callJavaFromCpp(const std::string &arg) {
    log_d(std::stringstream() << __FUNCTION__ << sep << arg);

    const auto env = getJNIEnv();
    log_d(std::stringstream() << env << sep << env->ExceptionCheck());

    jstring j_msg = env->NewStringUTF(arg.c_str());

    log_d(std::stringstream() << jniObj << sep << j_msg);

    env->CallVoidMethod(jniObj, jniMethod, j_msg);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_umasagashi_umasagashi_1app_MainActivity_callCppFromJava(JNIEnv *env, jobject thiz,
                                                                 jstring arg) {
    log_d(std::stringstream() << __FUNCTION__ << sep << javaVm << sep << arg);

    if (jniObj == nullptr) {
        jniObj = env->NewGlobalRef(thiz);
    }

    App::instance().set(jstring2string(env, arg));
}

extern "C"
jint JNI_OnLoad(JavaVM *vm, void *) {
    javaVm = vm;
    JNIEnv *env = getJNIEnv();
    jniCls = env->FindClass("com/umasagashi/umasagashi_app/MainActivity");
    jniMethod = env->GetMethodID(jniCls, "callJavaFromCpp", "(Ljava/lang/String;)V");

    log_d(std::stringstream() << __FUNCTION__ << sep << javaVm << sep << env << sep << jniCls << sep
                              << jniMethod << sep << env->ExceptionCheck());

    App::instance().setCallback(callJavaFromCpp);

    return JNI_VERSION_1_6;
}
