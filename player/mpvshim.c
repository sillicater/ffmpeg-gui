#include "mpvshim.h"
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <dlfcn.h>

static sh_endfile_cb g_endfile_cb = NULL;
static pthread_t g_thread;
static int g_thread_started = 0;
static void *g_handle = NULL;

// 持续消费 mpv 事件队列，避免队列积压；只关心播放结束
static void *event_loop(void *arg) {
  mpv_handle *h = (mpv_handle *)arg;
  while (1) {
    mpv_event *ev = mpv_wait_event(h, -1);
    if (!ev) continue;
    if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
    if (ev->event_id == MPV_EVENT_END_FILE) {
      mpv_event_end_file *ef = (mpv_event_end_file *)ev->data;
      if (g_endfile_cb && ef) g_endfile_cb(ef->reason);
    }
  }
  return NULL;
}

void *sh_create(void) {
  mpv_handle *h = mpv_create();
  if (!h) return NULL;
  g_handle = h;
  return h;
}

int sh_set_option(void *hp, const char *name, const char *value) {
  return mpv_set_option_string((mpv_handle *)hp, name, value);
}

int sh_initialize(void *hp) {
  int r = mpv_initialize((mpv_handle *)hp);
  if (r < 0) return r;
  if (!g_thread_started) {
    g_thread_started = 1;
    pthread_create(&g_thread, NULL, event_loop, hp);
    pthread_detach(g_thread);
  }
  return 0;
}

int sh_set_prop(void *hp, const char *name, const char *value) {
  return mpv_set_property_string((mpv_handle *)hp, name, value);
}

char *sh_get_prop(void *hp, const char *name) {
  char *v = mpv_get_property_string((mpv_handle *)hp, name);
  return v; // 由 mpv 分配，sh_free 释放
}

void sh_free(char *s) {
  if (s) mpv_free(s);
}

int sh_command(void *hp, const char *cmd) {
  return mpv_command_string((mpv_handle *)hp, cmd);
}

void sh_set_endfile_cb(sh_endfile_cb cb) { g_endfile_cb = cb; }

void sh_destroy(void *hp) {
  if (!hp) return;
  mpv_terminate_destroy((mpv_handle *)hp);
  g_handle = NULL;
}

const char *sh_error(int code) { return mpv_error_string(code); }

// ================= render API =================
// mpv 不再自己开窗口，而是把解码后的画面交给我们的 OpenGL 视图绘制。
static mpv_render_context *g_render = NULL;

static void *sh_get_proc_address(void *ctx, const char *name) {
  (void)ctx;
  return dlsym(RTLD_DEFAULT, name);
}

int sh_render_create(void *hp, sh_render_update_cb cb, void *ctx, char *err, int errLen) {
  if (g_render) return 0;
  if (!hp) return -1;
  mpv_opengl_init_params gl_init = { sh_get_proc_address, NULL, NULL };
  int advanced = 1; // 高级控制：由 update 回调告诉我们何时需要重绘
  mpv_render_param params[] = {
    { MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL },
    { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init },
    { MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced },
    { MPV_RENDER_PARAM_INVALID, NULL },
  };
  int r = mpv_render_context_create(&g_render, (mpv_handle *)hp, params);
  if (r < 0) {
    if (err && errLen > 0) snprintf(err, errLen, "%s", mpv_error_string(r));
    g_render = NULL;
    return r;
  }
  mpv_render_context_set_update_callback(g_render, cb, ctx);
  return 0;
}

int sh_render_draw(int fbo, int w, int h, int flip) {
  if (!g_render) return -1;
  mpv_opengl_fbo fbo_params = { .fbo = fbo, .w = w, .h = h, .internal_format = 0 };
  int flip_y = flip;
  mpv_render_param params[] = {
    { MPV_RENDER_PARAM_OPENGL_FBO, &fbo_params },
    { MPV_RENDER_PARAM_FLIP_Y, &flip_y },
    { MPV_RENDER_PARAM_INVALID, NULL },
  };
  return mpv_render_context_render(g_render, params);
}

unsigned long long sh_render_update(void) {
  return g_render ? mpv_render_context_update(g_render) : 0;
}

void sh_render_report_swap(void) {
  if (g_render) mpv_render_context_report_swap(g_render);
}

void sh_render_free(void) {
  if (!g_render) return;
  mpv_render_context_free(g_render);
  g_render = NULL;
}
