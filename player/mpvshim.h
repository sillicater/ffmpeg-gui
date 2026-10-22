#ifndef MPVSHIM_H
#define MPVSHIM_H

#include <stdint.h>

// 结束播放回调：reason 对应 mpv_end_file_reason
typedef void (*sh_endfile_cb)(int reason);

void *sh_create(void);
int sh_set_option(void *h, const char *name, const char *value);
int sh_initialize(void *h);
int sh_set_prop(void *h, const char *name, const char *value);
char *sh_get_prop(void *h, const char *name); // 用完需 sh_free
void sh_free(char *s);
int sh_command(void *h, const char *cmd);
void sh_set_endfile_cb(sh_endfile_cb cb);
void sh_destroy(void *h);
const char *sh_error(int code);

// ---- render API（把 mpv 画面画进我们自己的 OpenGL 视图）----
typedef void (*sh_render_update_cb)(void *ctx);
int sh_render_create(void *h, sh_render_update_cb cb, void *ctx, char *err, int errLen);
int sh_render_draw(int fbo, int w, int h, int flip);
unsigned long long sh_render_update(void);
void sh_render_report_swap(void);
void sh_render_free(void);

#endif
