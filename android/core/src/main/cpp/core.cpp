#ifdef LIBCLASH
#include <jni.h>
#include <cstring>
#include "jni_helper.h"
#include "libmeta.h"

extern "C"
JNIEXPORT jboolean JNICALL
Java_app_angelabettbox_core_Core_startTun(JNIEnv *env, jobject, const jint fd, jobject cb, const jlong epoch) {
    const auto interface = new_global(cb);
    return startTUN(fd, interface, epoch) ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT jlong JNICALL
Java_app_angelabettbox_core_Core_beginTunTransition(JNIEnv *, jobject) {
    return beginTunTransition();
}
extern "C"
JNIEXPORT jboolean JNICALL
Java_app_angelabettbox_core_Core_stopTunEpoch(JNIEnv *, jobject, jlong epoch) {
    return stopTunEpoch(epoch) ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT void JNICALL
Java_app_angelabettbox_core_Core_stopTun(JNIEnv *) {
    stopTun();
}

extern "C"
JNIEXPORT void JNICALL
Java_app_angelabettbox_core_Core_suspend(JNIEnv *, jobject, jint suspended) {
    suspend(suspended);
}


static jmethodID m_tun_interface_protect;
static jmethodID m_tun_interface_resolve_process;


static void release_jni_object_impl(void *obj) {
    ATTACH_JNI();
    del_global(static_cast<jobject>(obj));
}

static int call_tun_interface_protect_impl(void *tun_interface, const int fd) {
    if (tun_interface == nullptr || m_tun_interface_protect == nullptr) return 0;
    ATTACH_JNI();
    const jboolean ok = env->CallBooleanMethod(static_cast<jobject>(tun_interface),
                                               m_tun_interface_protect, fd);
    if (jni_catch_exception(env)) return 0;
    return ok == JNI_TRUE ? 1 : 0;
}

static const char *
call_tun_interface_resolve_process_impl(void *tun_interface, int protocol,
                                        const char *source,
                                        const char *target,
                                        const int uid) {
    if (tun_interface == nullptr) return strdup("");
    ATTACH_JNI();
    if (env->PushLocalFrame(8) < 0) {
        return strdup("");
    }
    const auto src_str = new_string(source != nullptr ? source : "");
    const auto dst_str = new_string(target != nullptr ? target : "");
    const auto packageName = reinterpret_cast<jstring>(env->CallObjectMethod(static_cast<jobject>(tun_interface),
                                                                       m_tun_interface_resolve_process,
                                                                       protocol,
                                                                       src_str,
                                                                       dst_str,
                                                                       uid));
    jni_catch_exception(env);
    const auto result = get_string(packageName);
    env->PopLocalFrame(nullptr);
    return result;
}

extern "C"
JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    initialize_jni(vm, env);

    const auto c_tun_interface = find_class("app/angelabettbox/core/TunInterface");

    m_tun_interface_protect = find_method(c_tun_interface, "protect", "(I)Z");
    m_tun_interface_resolve_process = find_method(c_tun_interface, "resolverProcess",
                                                  "(ILjava/lang/String;Ljava/lang/String;I)Ljava/lang/String;");

    registerCallbacks(&call_tun_interface_protect_impl,
                      &call_tun_interface_resolve_process_impl,
                      &release_jni_object_impl);
    return JNI_VERSION_1_6;
}
#endif
