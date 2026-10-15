%% mob_secure_store_nif — the NIF module behind MobSecureStore.
%%
%% iOS: priv/native/ios/mob_secure_store_nif.c (Keychain).
%% Android: priv/native/jni/mob_secure_store_nif.c (EncryptedSharedPreferences
%% through io.mob.securestore.MobSecureStoreBridge).
%%
%% Both are statically linked into the app; on the host, or on a native build
%% made before the plugin was activated, nothing is linked. on_load tolerates
%% that so the module still loads: available/0 then answers false (the NIF
%% replaces it with one answering true) and the store functions raise
%% nif_not_loaded. MobSecureStore asks available/0 before using the others.
-module(mob_secure_store_nif).
-export([available/0, store_get/1, store_put/2, store_delete/1]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_secure_store_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

available() -> false.

store_get(_Key) -> erlang:nif_error(nif_not_loaded).

store_put(_Key, _Value) -> erlang:nif_error(nif_not_loaded).

store_delete(_Key) -> erlang:nif_error(nif_not_loaded).
