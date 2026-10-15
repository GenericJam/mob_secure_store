/*
 * mob_secure_store_nif.c (Android) — MobSecureStore's NIF over
 * EncryptedSharedPreferences, through the Kotlin bridge
 * io.mob.securestore.MobSecureStoreBridge (priv/native/android).
 *
 * Ported from Operator's c_src/operator_secure_store.c (Android JNI branch),
 * itself ported from muster_app's muster_secure_store.c. Unlike Operator's,
 * keys and values cross JNI as byte arrays, so values may be any binary
 * (NULs included): the bridge stores them Base64-encoded.
 *
 * Function surface (the stubs in src/mob_secure_store_nif.erl):
 *   available()          -> true
 *   store_get(Key)       -> {ok, Value} | not_found | {error, {jni, Reason}}
 *   store_put(Key, Val)  -> ok | {error, {jni, Reason}}
 *   store_delete(Key)    -> ok | {error, {jni, Reason}}   (absent key: ok)
 *
 * Reason: no_jenv | bridge_not_registered | alloc | call_failed (the bridge
 * threw; it logs why under the MobSecureStore tag) | commit_failed.
 *
 * The bridge class and method IDs are cached by nativeRegister, which the
 * generated MobPluginBootstrap.registerAll calls (via the bridge's register())
 * from MainActivity.onCreate, before the BEAM starts. FindClass from a BEAM
 * thread would search the system class loader and miss the app's classes.
 * The store calls are dirty IO NIFs: commit() writes to disk.
 */

#include <erl_nif.h>
#include <jni.h>
#include <string.h>

/* mob core exports, linked into the same .so. */
extern JNIEnv *get_jenv(int *attached);
extern JavaVM *g_jvm;

static jclass g_cls = NULL;
static jmethodID g_get = NULL;
static jmethodID g_put = NULL;
static jmethodID g_delete = NULL;

JNIEXPORT void JNICALL
Java_io_mob_securestore_MobSecureStoreBridge_nativeRegister(JNIEnv *jenv, jclass cls) {
    if (g_cls != NULL)
        return;

    jmethodID get = (*jenv)->GetStaticMethodID(jenv, cls, "getBridge", "([B)[B");
    jmethodID put = (*jenv)->GetStaticMethodID(jenv, cls, "putBridge", "([B[B)Z");
    jmethodID del = (*jenv)->GetStaticMethodID(jenv, cls, "deleteBridge", "([B)Z");
    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        return;
    }
    if (get == NULL || put == NULL || del == NULL)
        return;

    g_get = get;
    g_put = put;
    g_delete = del;
    g_cls = (jclass)(*jenv)->NewGlobalRef(jenv, cls);
}

static ERL_NIF_TERM mss_jni_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(
        env, enif_make_atom(env, "error"),
        enif_make_tuple2(env, enif_make_atom(env, "jni"), enif_make_atom(env, reason))
    );
}

/* A new local byte[] holding bin, or NULL (exception cleared). */
static jbyteArray mss_bytes(JNIEnv *jenv, ErlNifBinary *bin) {
    jbyteArray arr = (*jenv)->NewByteArray(jenv, (jsize)bin->size);
    if (arr == NULL || (*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        return NULL;
    }
    (*jenv)->SetByteArrayRegion(jenv, arr, 0, (jsize)bin->size, (const jbyte *)bin->data);
    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        (*jenv)->DeleteLocalRef(jenv, arr);
        return NULL;
    }
    return arr;
}

static void mss_detach(int attached) {
    if (attached)
        (*g_jvm)->DetachCurrentThread(g_jvm);
}

static ERL_NIF_TERM mss_available(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return enif_make_atom(env, "true");
}

static ERL_NIF_TERM mss_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary key;
    if (!enif_inspect_binary(env, argv[0], &key))
        return enif_make_badarg(env);
    if (g_cls == NULL)
        return mss_jni_error(env, "bridge_not_registered");

    int attached = 0;
    JNIEnv *jenv = get_jenv(&attached);
    if (!jenv)
        return mss_jni_error(env, "no_jenv");

    ERL_NIF_TERM result;
    jbyteArray jkey = mss_bytes(jenv, &key);
    if (!jkey) {
        result = mss_jni_error(env, "alloc");
        goto done;
    }

    jbyteArray ret = (jbyteArray)(*jenv)->CallStaticObjectMethod(jenv, g_cls, g_get, jkey);
    (*jenv)->DeleteLocalRef(jenv, jkey);

    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        result = mss_jni_error(env, "call_failed");
        goto done;
    }

    if (ret == NULL) {
        result = enif_make_atom(env, "not_found");
        goto done;
    }

    jsize len = (*jenv)->GetArrayLength(jenv, ret);
    ErlNifBinary bin;
    if (!enif_alloc_binary((size_t)len, &bin)) {
        (*jenv)->DeleteLocalRef(jenv, ret);
        result = mss_jni_error(env, "alloc");
        goto done;
    }
    (*jenv)->GetByteArrayRegion(jenv, ret, 0, len, (jbyte *)bin.data);
    (*jenv)->DeleteLocalRef(jenv, ret);
    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        enif_release_binary(&bin);
        result = mss_jni_error(env, "call_failed");
        goto done;
    }

    result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &bin));

done:
    mss_detach(attached);
    return result;
}

static ERL_NIF_TERM mss_put(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary key, val;
    if (!enif_inspect_binary(env, argv[0], &key) || !enif_inspect_binary(env, argv[1], &val))
        return enif_make_badarg(env);
    if (g_cls == NULL)
        return mss_jni_error(env, "bridge_not_registered");

    int attached = 0;
    JNIEnv *jenv = get_jenv(&attached);
    if (!jenv)
        return mss_jni_error(env, "no_jenv");

    ERL_NIF_TERM result;
    jbyteArray jkey = mss_bytes(jenv, &key);
    jbyteArray jval = jkey ? mss_bytes(jenv, &val) : NULL;
    if (!jkey || !jval) {
        if (jkey)
            (*jenv)->DeleteLocalRef(jenv, jkey);
        result = mss_jni_error(env, "alloc");
        goto done;
    }

    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, g_cls, g_put, jkey, jval);
    (*jenv)->DeleteLocalRef(jenv, jkey);
    (*jenv)->DeleteLocalRef(jenv, jval);

    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        result = mss_jni_error(env, "call_failed");
        goto done;
    }

    result = ok ? enif_make_atom(env, "ok") : mss_jni_error(env, "commit_failed");

done:
    mss_detach(attached);
    return result;
}

static ERL_NIF_TERM mss_delete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary key;
    if (!enif_inspect_binary(env, argv[0], &key))
        return enif_make_badarg(env);
    if (g_cls == NULL)
        return mss_jni_error(env, "bridge_not_registered");

    int attached = 0;
    JNIEnv *jenv = get_jenv(&attached);
    if (!jenv)
        return mss_jni_error(env, "no_jenv");

    ERL_NIF_TERM result;
    jbyteArray jkey = mss_bytes(jenv, &key);
    if (!jkey) {
        result = mss_jni_error(env, "alloc");
        goto done;
    }

    jboolean ok = (*jenv)->CallStaticBooleanMethod(jenv, g_cls, g_delete, jkey);
    (*jenv)->DeleteLocalRef(jenv, jkey);

    if ((*jenv)->ExceptionCheck(jenv)) {
        (*jenv)->ExceptionClear(jenv);
        result = mss_jni_error(env, "call_failed");
        goto done;
    }

    /* SharedPreferences.remove of an absent key commits true: absent is ok. */
    result = ok ? enif_make_atom(env, "ok") : mss_jni_error(env, "commit_failed");

done:
    mss_detach(attached);
    return result;
}

static ErlNifFunc nif_funcs[] = {
    {"available", 0, mss_available, 0},
    {"store_get", 1, mss_get, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"store_put", 2, mss_put, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"store_delete", 1, mss_delete, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(mob_secure_store_nif, nif_funcs, NULL, NULL, NULL, NULL)
