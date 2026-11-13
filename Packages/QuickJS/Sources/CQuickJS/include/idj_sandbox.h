#ifndef IDJ_SANDBOX_H
#define IDJ_SANDBOX_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque per-plugin sandbox (one QuickJS runtime + one eval-less context).
typedef struct IDJBox IDJBox;

/// Host callback. `name` = capability ("http.request", "html.select", …), `args` = JSON text.
/// Return a malloc'd UTF-8 string (JSON text) or NULL for `undefined`. Set *is_error = 1 and return
/// JSON `{"code":"E_…","message":"…"}` to throw inside JS.
typedef char *(*idj_host_fn)(void *opaque, const char *name, const char *args, int *is_error);

IDJBox *idj_new(size_t mem_limit, size_t stack_limit, idj_host_fn fn, void *opaque);
/// idj_new with eval / Function enabled (book-source scripts only; plugins use idj_new).
IDJBox *idj_new_with_eval(size_t mem_limit, size_t stack_limit, idj_host_fn fn, void *opaque);
/// Runs the trusted prelude (script) and then the plugin (ES module). Returns 0 on success; on failure *err
/// receives a malloc'd JSON error ({"code","message"}).
int idj_load(IDJBox *b, const char *prelude, const char *src, const char *filename, double timeout_sec, char **err);
/// 1 when the plugin's default export has a function named `fn`.
int idj_has(IDJBox *b, const char *fn);
/// Calls `default[fn](arg)`, awaits the returned promise, returns malloc'd JSON text of the result
/// (or "null"). On failure returns NULL and *err receives malloc'd JSON {"code","message"}.
char *idj_call(IDJBox *b, const char *fn, const char *arg_json, double timeout_sec, char **err);
/// Evaluates a trusted snippet in the sandbox context (tests only; still eval-less for the snippet's own code).
char *idj_eval_script(IDJBox *b, const char *src, double timeout_sec, char **err);
/// Same as idj_eval_script, compiled without strict mode (Legado scripts).
char *idj_eval_sloppy(IDJBox *b, const char *src, double timeout_sec, char **err);
/// Bytes currently allocated by this runtime.
size_t idj_memory_used(IDJBox *b);
void idj_free(IDJBox *b);
void idj_str_free(char *s);

#ifdef __cplusplus
}
#endif
#endif
