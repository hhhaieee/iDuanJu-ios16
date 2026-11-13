// i短剧 plugin sandbox on top of quickjs-ng. See README.md for the isolation model.
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "quickjs.h"
#include "include/idj_sandbox.h"

struct IDJBox {
    JSRuntime *rt;
    JSContext *ctx;
    JSValue plugin;
    double deadline;
    int interrupted;
    idj_host_fn fn;
    void *opaque;
};

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static int interrupt_cb(JSRuntime *rt, void *opaque) {
    IDJBox *b = opaque;
    if (b->deadline > 0 && now_s() > b->deadline) { b->interrupted = 1; return 1; }
    return 0;
}

static char *dupstr(const char *s) {
    size_t n = strlen(s);
    char *r = malloc(n + 1);
    if (r) memcpy(r, s, n + 1);
    return r;
}

/// JSON-escapes `s` into a malloc'd {"code":…,"message":…} string without needing a JS context.
static char *err_json(const char *code, const char *msg) {
    if (!msg) msg = "";
    size_t n = strlen(msg), cap = n * 6 + strlen(code) + 40;
    char *out = malloc(cap), *p = out;
    if (!out) return NULL;
    p += sprintf(p, "{\"code\":\"%s\",\"message\":\"", code);
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)msg[i];
        if (c == '"' || c == '\\') { *p++ = '\\'; *p++ = c; }
        else if (c < 0x20) { p += sprintf(p, "\\u%04x", c); }
        else *p++ = c;
    }
    strcpy(p, "\"}");
    return out;
}

/// Converts the pending exception into {"code","message"}; plugin errors created by host.error carry `.code`.
static char *take_exception(IDJBox *b) {
    JSContext *ctx = b->ctx;
    JSValue e = JS_GetException(ctx);
    char *out;
    if (b->interrupted) {
        out = err_json("E_TIMEOUT", "插件执行超时，已被中断");
    } else {
        const char *code = NULL, *msg = NULL;
        JSValue c = JS_UNDEFINED, m = JS_UNDEFINED;
        if (JS_IsObject(e)) {
            c = JS_GetPropertyStr(ctx, e, "code");
            m = JS_GetPropertyStr(ctx, e, "message");
            if (JS_IsString(c)) code = JS_ToCString(ctx, c);
            msg = JS_ToCString(ctx, JS_IsUndefined(m) ? e : m);
        } else {
            msg = JS_ToCString(ctx, e);
        }
        const char *cc = code && strncmp(code, "E_", 2) == 0 ? code : "E_INTERNAL";
        if (msg && strstr(msg, "out of memory")) cc = "E_MEMORY";
        if (msg && strstr(msg, "stack overflow")) cc = "E_MEMORY";
        out = err_json(cc, msg ? msg : "unknown error");
        if (code) JS_FreeCString(ctx, code);
        if (msg) JS_FreeCString(ctx, msg);
        JS_FreeValue(ctx, c);
        JS_FreeValue(ctx, m);
    }
    JS_FreeValue(ctx, e);
    return out;
}

static JSValue js_host(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    IDJBox *b = JS_GetContextOpaque(ctx);
    if (argc < 1) return JS_ThrowTypeError(ctx, "host: missing name");
    const char *name = JS_ToCString(ctx, argv[0]);
    if (!name) return JS_EXCEPTION;
    const char *args = argc > 1 && JS_IsString(argv[1]) ? JS_ToCString(ctx, argv[1]) : NULL;
    int is_err = 0;
    // The JS budget only counts script execution: time spent inside a host call (network, CF pass) is
    // bounded by the host's own timeouts, so pause the deadline while the host works.
    double remain = b->deadline > 0 ? b->deadline - now_s() : 0;
    char *res = b->fn(b->opaque, name, args ? args : "null", &is_err);
    if (b->deadline > 0) b->deadline = now_s() + (remain > 0.001 ? remain : 0.001);
    JS_FreeCString(ctx, name);
    if (args) JS_FreeCString(ctx, args);
    if (!res) return JS_UNDEFINED;
    if (is_err) {
        JSValue o = JS_ParseJSON(ctx, res, strlen(res), "<host>");
        free(res);
        JSValue e = JS_NewError(ctx);
        if (JS_IsObject(o)) {
            JS_SetPropertyStr(ctx, e, "code", JS_GetPropertyStr(ctx, o, "code"));
            JS_SetPropertyStr(ctx, e, "message", JS_GetPropertyStr(ctx, o, "message"));
        }
        JS_FreeValue(ctx, o);
        return JS_Throw(ctx, e);
    }
    JSValue v = JS_NewString(ctx, res);
    free(res);
    return v;
}

static IDJBox *new_box(size_t mem_limit, size_t stack_limit, idj_host_fn fn, void *opaque, int with_eval) {
    IDJBox *b = calloc(1, sizeof(IDJBox));
    if (!b) return NULL;
    b->fn = fn;
    b->opaque = opaque;
    b->plugin = JS_UNDEFINED;
    b->rt = JS_NewRuntime();
    if (!b->rt) { free(b); return NULL; }
    JS_SetMemoryLimit(b->rt, mem_limit);
    JS_SetMaxStackSize(b->rt, stack_limit);
    JS_SetInterruptHandler(b->rt, interrupt_cb, b);
    // Sandbox context: everything a parser plugin needs, but no Eval intrinsic (→ no eval / Function ctor),
    // no Performance, no std/os modules, no module loader.
    JSContext *ctx = JS_NewContextRaw(b->rt);
    JS_AddIntrinsicBaseObjects(ctx);
    JS_AddIntrinsicDate(ctx);
    JS_AddIntrinsicRegExp(ctx);
    JS_AddIntrinsicJSON(ctx);
    JS_AddIntrinsicMapSet(ctx);
    JS_AddIntrinsicTypedArrays(ctx);
    JS_AddIntrinsicPromise(ctx);
    JS_AddIntrinsicBigInt(ctx);
    if (with_eval) JS_AddIntrinsicEval(ctx);
    JS_SetContextOpaque(ctx, b);
    b->ctx = ctx;
    JSValue global = JS_GetGlobalObject(ctx);
    JS_DefinePropertyValueStr(ctx, global, "__host", JS_NewCFunction(ctx, js_host, "__host", 2), JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE);
    JS_FreeValue(ctx, global);
    return b;
}

IDJBox *idj_new(size_t mem_limit, size_t stack_limit, idj_host_fn fn, void *opaque) {
    return new_box(mem_limit, stack_limit, fn, opaque, 0);
}

/// Same sandbox with eval / new Function enabled: 「阅读」 book-source scripts (code the user imported) use them.
/// Plugins keep using idj_new.
IDJBox *idj_new_with_eval(size_t mem_limit, size_t stack_limit, idj_host_fn fn, void *opaque) {
    return new_box(mem_limit, stack_limit, fn, opaque, 1);
}

/// Compiles `src` in a throw-away context that has the parser, returns bytecode (js_free_rt it).
static uint8_t *compile_mode(IDJBox *b, const char *src, const char *filename, int module, int strict, size_t *len, char **err) {
    JSContext *c = JS_NewContextRaw(b->rt);
    JS_AddIntrinsicBaseObjects(c);
    JS_AddIntrinsicEval(c);
    JS_AddIntrinsicRegExpCompiler(c);
    JSValue f = JS_Eval(c, src, strlen(src), filename,
                        (module ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL) | JS_EVAL_FLAG_COMPILE_ONLY | (strict || module ? JS_EVAL_FLAG_STRICT : 0));
    uint8_t *buf = NULL;
    if (JS_IsException(f)) {
        JSValue e = JS_GetException(c);
        const char *m = JS_ToCString(c, e);
        *err = err_json("E_SYNTAX", m ? m : "syntax error");
        if (m) JS_FreeCString(c, m);
        JS_FreeValue(c, e);
    } else {
        buf = JS_WriteObject(c, len, f, JS_WRITE_OBJ_BYTECODE);
        if (!buf) *err = err_json("E_INTERNAL", "bytecode write failed");
    }
    JS_FreeValue(c, f);
    JS_FreeContext(c);
    return buf;
}

static uint8_t *compile(IDJBox *b, const char *src, const char *filename, int module, size_t *len, char **err) {
    return compile_mode(b, src, filename, module, 1, len, err);
}

/// Drains the job queue until `v` (a promise) settles. Returns the settled value (owned) or JS_EXCEPTION.
static JSValue await_value(IDJBox *b, JSValue v) {
    JSContext *ctx = b->ctx;
    for (;;) {
        JSPromiseStateEnum st = JS_PromiseState(ctx, v);
        if ((int)st < 0) return v;                       // not a promise
        if (st == JS_PROMISE_FULFILLED) { JSValue r = JS_PromiseResult(ctx, v); JS_FreeValue(ctx, v); return r; }
        if (st == JS_PROMISE_REJECTED) { JSValue r = JS_PromiseResult(ctx, v); JS_FreeValue(ctx, v); return JS_Throw(ctx, r); }
        JSContext *jc;
        int k = JS_ExecutePendingJob(b->rt, &jc);
        if (k < 0) { JS_FreeValue(ctx, v); return JS_EXCEPTION; }
        if (k == 0) {
            JS_FreeValue(ctx, v);
            JSValue e = JS_NewError(ctx);
            JS_SetPropertyStr(ctx, e, "code", JS_NewString(ctx, "E_INTERNAL"));
            JS_SetPropertyStr(ctx, e, "message", JS_NewString(ctx, "Promise 永远不会完成（插件里没有可用的异步来源）"));
            return JS_Throw(ctx, e);
        }
    }
}

static int run_bytecode(IDJBox *b, uint8_t *buf, size_t len, int module, JSValue *out, char **err) {
    JSContext *ctx = b->ctx;
    JSValue obj = JS_ReadObject(ctx, buf, len, JS_READ_OBJ_BYTECODE);
    js_free_rt(b->rt, buf);
    if (JS_IsException(obj)) { *err = take_exception(b); return -1; }
    JSModuleDef *md = NULL;
    if (module) {
        if (JS_ResolveModule(ctx, obj) < 0) { JS_FreeValue(ctx, obj); *err = take_exception(b); return -1; }
        md = (JSModuleDef *)JS_VALUE_GET_PTR(obj);
    }
    JSValue r = JS_EvalFunction(ctx, obj);
    if (JS_IsException(r)) { *err = take_exception(b); return -1; }
    r = await_value(b, r);
    if (JS_IsException(r)) { *err = take_exception(b); return -1; }
    JS_FreeValue(ctx, r);
    if (module && out) {
        JSValue ns = JS_GetModuleNamespace(ctx, md);
        *out = JS_GetPropertyStr(ctx, ns, "default");
        JS_FreeValue(ctx, ns);
    }
    return 0;
}

int idj_load(IDJBox *b, const char *prelude, const char *src, const char *filename, double timeout_sec, char **err) {
    *err = NULL;
    JS_UpdateStackTop(b->rt);
    b->interrupted = 0;
    b->deadline = now_s() + timeout_sec;
    size_t len = 0;
    uint8_t *bc = compile(b, prelude, "<prelude>", 0, &len, err);
    int rc = -1;
    if (bc && run_bytecode(b, bc, len, 0, NULL, err) == 0) {
        bc = compile(b, src, filename, 1, &len, err);
        JSValue def = JS_UNDEFINED;
        if (bc && run_bytecode(b, bc, len, 1, &def, err) == 0) {
            if (JS_IsObject(def)) { b->plugin = def; rc = 0; }
            else { JS_FreeValue(b->ctx, def); *err = err_json("E_SYNTAX", "插件必须 export default 一个对象"); }
        }
    }
    b->deadline = 0;
    return rc;
}

int idj_has(IDJBox *b, const char *fn) {
    if (!JS_IsObject(b->plugin)) return 0;
    JSValue f = JS_GetPropertyStr(b->ctx, b->plugin, fn);
    int r = JS_IsFunction(b->ctx, f);
    JS_FreeValue(b->ctx, f);
    return r;
}

static char *stringify(IDJBox *b, JSValue v, char **err) {
    JSContext *ctx = b->ctx;
    if (JS_IsUndefined(v)) return dupstr("null");
    JSValue s = JS_JSONStringify(ctx, v, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(s)) { *err = take_exception(b); return NULL; }
    if (JS_IsUndefined(s)) return dupstr("null");
    const char *c = JS_ToCString(ctx, s);
    char *r = c ? dupstr(c) : NULL;
    if (c) JS_FreeCString(ctx, c);
    JS_FreeValue(ctx, s);
    if (!r) *err = err_json("E_INTERNAL", "result not serializable");
    return r;
}

char *idj_call(IDJBox *b, const char *fn, const char *arg_json, double timeout_sec, char **err) {
    *err = NULL;
    JSContext *ctx = b->ctx;
    if (!JS_IsObject(b->plugin)) { *err = err_json("E_INTERNAL", "插件未加载"); return NULL; }
    JS_UpdateStackTop(b->rt);
    b->interrupted = 0;
    b->deadline = now_s() + timeout_sec;
    char *out = NULL;
    JSValue f = JS_GetPropertyStr(ctx, b->plugin, fn);
    if (!JS_IsFunction(ctx, f)) {
        *err = err_json("E_UNSUPPORTED", "插件没有实现这个函数");
    } else {
        JSValue arg = JS_ParseJSON(ctx, arg_json ? arg_json : "null", strlen(arg_json ? arg_json : "null"), "<arg>");
        if (JS_IsException(arg)) { *err = take_exception(b); }
        else {
            JSValue r = JS_Call(ctx, f, b->plugin, 1, (JSValueConst *)&arg);
            JS_FreeValue(ctx, arg);
            if (JS_IsException(r)) *err = take_exception(b);
            else {
                r = await_value(b, r);
                if (JS_IsException(r)) *err = take_exception(b);
                else { out = stringify(b, r, err); JS_FreeValue(ctx, r); }
            }
        }
    }
    JS_FreeValue(ctx, f);
    JS_RunGC(b->rt);
    b->deadline = 0;
    return out;
}

static char *eval_impl(IDJBox *b, const char *src, double timeout_sec, int strict, char **err) {
    *err = NULL;
    JS_UpdateStackTop(b->rt);
    b->interrupted = 0;
    b->deadline = now_s() + timeout_sec;
    size_t len = 0;
    char *out = NULL;
    uint8_t *bc = compile_mode(b, src, "<script>", 0, strict, &len, err);
    if (bc) {
        JSValue obj = JS_ReadObject(b->ctx, bc, len, JS_READ_OBJ_BYTECODE);
        js_free_rt(b->rt, bc);
        JSValue r = JS_IsException(obj) ? JS_EXCEPTION : JS_EvalFunction(b->ctx, obj);
        if (!JS_IsException(r)) r = await_value(b, r);
        if (JS_IsException(r)) *err = take_exception(b);
        else { out = stringify(b, r, err); JS_FreeValue(b->ctx, r); }
    }
    b->deadline = 0;
    return out;
}

/// Like idj_eval_script but compiled in sloppy mode (Legado book-source scripts assign undeclared globals).
/// Still runs in the eval-less sandbox context; the completion value of the script is returned as JSON.
char *idj_eval_sloppy(IDJBox *b, const char *src, double timeout_sec, char **err) {
    return eval_impl(b, src, timeout_sec, 0, err);
}

char *idj_eval_script(IDJBox *b, const char *src, double timeout_sec, char **err) {
    return eval_impl(b, src, timeout_sec, 1, err);
}

size_t idj_memory_used(IDJBox *b) {
    JSMemoryUsage u;
    JS_ComputeMemoryUsage(b->rt, &u);
    return (size_t)u.malloc_size;
}

void idj_free(IDJBox *b) {
    if (!b) return;
    JS_FreeValue(b->ctx, b->plugin);
    JS_FreeContext(b->ctx);
    JS_FreeRuntime(b->rt);
    free(b);
}

void idj_str_free(char *s) { free(s); }
