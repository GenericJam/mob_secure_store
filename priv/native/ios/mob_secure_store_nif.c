/*
 * mob_secure_store_nif.c (iOS) — MobSecureStore's NIF over the iOS Keychain.
 *
 * Ported from Operator's c_src/operator_secure_store.c (Keychain branch),
 * itself ported from muster_app's muster_secure_store.c. Wraps SecItemAdd /
 * SecItemUpdate / SecItemCopyMatching / SecItemDelete from
 * Security.framework (the manifest declares the framework).
 *
 * Item attributes:
 *   kSecClass           = kSecClassGenericPassword
 *   kSecAttrService     = "mob_secure_store" (each app has its own keychain
 *                         access group, so the service only has to keep our
 *                         items apart from the app's other keychain items)
 *   kSecAttrAccount     = the key (UTF-8)
 *   kSecAttrAccessible  = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
 *                         (set on add only; see mss_put)
 *   kSecValueData       = the value bytes, any binary
 *
 * Function surface (the stubs in src/mob_secure_store_nif.erl):
 *   available()          -> true
 *   store_get(Key)       -> {ok, Value} | not_found | {error, {sec, OSStatus}}
 *                           | {error, no_data} (success without the data)
 *   store_put(Key, Val)  -> ok | {error, {sec, OSStatus}}
 *   store_delete(Key)    -> ok | {error, {sec, OSStatus}}   (absent key: ok)
 *
 * A failed CoreFoundation allocation is {error, {sec, errSecAllocate}}. A key
 * that isn't UTF-8 is badarg (MobSecureStore checks first). The store calls
 * are dirty IO NIFs: SecItem* is an IPC to securityd and may block.
 */

#include <erl_nif.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#define MSS_SERVICE CFSTR("mob_secure_store")

/* The key as a CFString (UTF-8). NULL when the bytes aren't UTF-8. */
static CFStringRef mss_account(ErlNifBinary *bin) {
    return CFStringCreateWithBytes(
        kCFAllocatorDefault, bin->data, (CFIndex)bin->size, kCFStringEncodingUTF8, false
    );
}

static CFMutableDictionaryRef mss_dict(void) {
    return CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
}

/* class + service + account: what identifies an item. kSecAttrAccessible is
 * deliberately not here; in a query it would become a match filter, so a
 * later change of the constant would orphan existing items. NULL when the
 * allocation fails. */
static CFMutableDictionaryRef mss_base_query(CFStringRef account) {
    CFMutableDictionaryRef query = mss_dict();
    if (!query)
        return NULL;

    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, MSS_SERVICE);
    CFDictionarySetValue(query, kSecAttrAccount, account);
    return query;
}

/* {error, {sec, OSStatus}} */
static ERL_NIF_TERM mss_sec_error(ErlNifEnv *env, OSStatus st) {
    return enif_make_tuple2(
        env, enif_make_atom(env, "error"),
        enif_make_tuple2(env, enif_make_atom(env, "sec"), enif_make_int(env, (int)st))
    );
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

    CFStringRef account = mss_account(&key);
    if (!account)
        return enif_make_badarg(env);

    CFMutableDictionaryRef query = mss_base_query(account);
    if (!query) {
        CFRelease(account);
        return mss_sec_error(env, errSecAllocate);
    }
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);

    CFTypeRef out = NULL;
    OSStatus st = SecItemCopyMatching(query, &out);
    CFRelease(query);
    CFRelease(account);

    ERL_NIF_TERM result;

    if (st == errSecItemNotFound) {
        result = enif_make_atom(env, "not_found");
    } else if (st != errSecSuccess) {
        result = mss_sec_error(env, st);
    } else if (out == NULL || CFGetTypeID(out) != CFDataGetTypeID()) {
        /* Success that didn't return the data: a store failure, not an
         * absent key. */
        result = enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "no_data"));
    } else {
        CFDataRef data = (CFDataRef)out;
        CFIndex len = CFDataGetLength(data);
        ErlNifBinary bin;
        if (!enif_alloc_binary((size_t)len, &bin)) {
            result = mss_sec_error(env, errSecAllocate);
        } else {
            memcpy(bin.data, CFDataGetBytePtr(data), (size_t)len);
            result = enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &bin));
        }
    }

    if (out)
        CFRelease(out);
    return result;
}

static ERL_NIF_TERM mss_put(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary key, val;
    if (!enif_inspect_binary(env, argv[0], &key) || !enif_inspect_binary(env, argv[1], &val))
        return enif_make_badarg(env);

    CFStringRef account = mss_account(&key);
    if (!account)
        return enif_make_badarg(env);

    CFDataRef value = CFDataCreate(kCFAllocatorDefault, val.data, (CFIndex)val.size);
    if (!value) {
        CFRelease(account);
        return mss_sec_error(env, errSecAllocate);
    }

    /* Add first, update on errSecDuplicateItem. Update-first would race: two
     * writers both see not-found, both add, the second gets a duplicate.
     * kSecAttrAccessible goes on the add only (see mss_base_query). */
    CFMutableDictionaryRef add = mss_base_query(account);
    if (!add) {
        CFRelease(value);
        CFRelease(account);
        return mss_sec_error(env, errSecAllocate);
    }
    CFDictionarySetValue(add, kSecValueData, value);
    CFDictionarySetValue(add, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);

    OSStatus st = SecItemAdd(add, NULL);
    CFRelease(add);

    if (st == errSecDuplicateItem) {
        CFMutableDictionaryRef match = mss_base_query(account);
        CFMutableDictionaryRef attrs = mss_dict();
        if (match && attrs) {
            CFDictionarySetValue(attrs, kSecValueData, value);
            st = SecItemUpdate(match, attrs);
        } else {
            st = errSecAllocate;
        }
        if (attrs)
            CFRelease(attrs);
        if (match)
            CFRelease(match);
    }

    CFRelease(value);
    CFRelease(account);
    return st == errSecSuccess ? enif_make_atom(env, "ok") : mss_sec_error(env, st);
}

static ERL_NIF_TERM mss_delete(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary key;
    if (!enif_inspect_binary(env, argv[0], &key))
        return enif_make_badarg(env);

    CFStringRef account = mss_account(&key);
    if (!account)
        return enif_make_badarg(env);

    CFMutableDictionaryRef query = mss_base_query(account);
    if (!query) {
        CFRelease(account);
        return mss_sec_error(env, errSecAllocate);
    }
    OSStatus st = SecItemDelete(query);
    CFRelease(query);
    CFRelease(account);

    return (st == errSecSuccess || st == errSecItemNotFound) ? enif_make_atom(env, "ok")
                                                             : mss_sec_error(env, st);
}

static ErlNifFunc nif_funcs[] = {
    {"available", 0, mss_available, 0},
    {"store_get", 1, mss_get, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"store_put", 2, mss_put, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"store_delete", 1, mss_delete, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(mob_secure_store_nif, nif_funcs, NULL, NULL, NULL, NULL)
