/**
 * @file query_reply.h
 *
 * Query reply - encode the reply that a client gives to a terminal query.
 */

#ifndef GHOSTTY_VT_QUERY_REPLY_H
#define GHOSTTY_VT_QUERY_REPLY_H

/** @defgroup query_reply Query reply
 *
 * A host that offers a terminal query to another party (see
 * GHOSTTY_TERMINAL_OPT_QUERY) and gets structured values back needs the bytes
 * that the program expects. ghostty_query_reply_encode() writes them, so the
 * host never writes terminal protocol bytes itself.
 *
 * | Kind | Query | Reply |
 * |---|---|---|
 * | `GHOSTTY_QUERY_REPLY_PIXELS_TEXT_AREA` | CSI 14 t, CSI 14 ; 2 t | CSI 4 ; height ; width t |
 * | `GHOSTTY_QUERY_REPLY_PIXELS_CELL` | CSI 16 t | CSI 6 ; height ; width t |
 * | `GHOSTTY_QUERY_REPLY_PIXELS_SCREEN` | CSI 15 t | CSI 5 ; height ; width t |
 * | `GHOSTTY_QUERY_REPLY_CHARS_SCREEN` | CSI 19 t | CSI 9 ; rows ; cols t |
 * | `GHOSTTY_QUERY_REPLY_WINDOW_STATE` | CSI 11 t | CSI 2 t if iconified, else CSI 1 t |
 * | `GHOSTTY_QUERY_REPLY_WINDOW_POSITION` | CSI 13 t, CSI 13 ; 2 t | CSI 3 ; x ; y t |
 * | `GHOSTTY_QUERY_REPLY_WINDOW_TITLE` | CSI 21 t | OSC l text ST |
 * | `GHOSTTY_QUERY_REPLY_ICON_LABEL` | CSI 20 t | OSC L text ST |
 * | `GHOSTTY_QUERY_REPLY_CLIPBOARD` | OSC 52 ; selection ; ? | OSC 52 ; selection ; base64 terminator |
 *
 * The color scheme reply (CSI ? 997 ; 1 n and CSI ? 997 ; 2 n) is written by
 * ghostty_color_scheme_report_encode().
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/osc.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * What a reply answers.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Never valid. A zeroed value is not a reply. */
  GHOSTTY_QUERY_REPLY_INVALID = 0,
  /** CSI 4 ; height ; width t. Answers CSI 14 t and CSI 14 ; 2 t. */
  GHOSTTY_QUERY_REPLY_PIXELS_TEXT_AREA = 1,
  /** CSI 6 ; height ; width t. Answers CSI 16 t. */
  GHOSTTY_QUERY_REPLY_PIXELS_CELL = 2,
  /** CSI 5 ; height ; width t. Answers CSI 15 t. */
  GHOSTTY_QUERY_REPLY_PIXELS_SCREEN = 3,
  /** CSI 9 ; rows ; cols t. Answers CSI 19 t. */
  GHOSTTY_QUERY_REPLY_CHARS_SCREEN = 4,
  /** CSI 2 t when iconified, else CSI 1 t. Answers CSI 11 t. */
  GHOSTTY_QUERY_REPLY_WINDOW_STATE = 5,
  /** CSI 3 ; x ; y t. Answers CSI 13 t and CSI 13 ; 2 t. */
  GHOSTTY_QUERY_REPLY_WINDOW_POSITION = 6,
  /** OSC l text ST. Answers CSI 21 t. */
  GHOSTTY_QUERY_REPLY_WINDOW_TITLE = 7,
  /** OSC L text ST. Answers CSI 20 t. */
  GHOSTTY_QUERY_REPLY_ICON_LABEL = 8,
  /** OSC 52 ; selection ; base64 terminator. Answers an OSC 52 read. */
  GHOSTTY_QUERY_REPLY_CLIPBOARD = 9,
  GHOSTTY_QUERY_REPLY_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyQueryReplyKind;

/**
 * A reply. Each kind reads only the fields that it names. Set `size` with
 * GHOSTTY_INIT_SIZED() and zero the other fields.
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;

  /** What the reply answers. */
  GhosttyQueryReplyKind kind;

  /** PIXELS_*: the width in pixels. */
  uint32_t width;

  /** PIXELS_*: the height in pixels. */
  uint32_t height;

  /** CHARS_SCREEN: the number of rows. */
  uint32_t rows;

  /** CHARS_SCREEN: the number of columns. */
  uint32_t cols;

  /** WINDOW_POSITION: the horizontal position. */
  int32_t x;

  /** WINDOW_POSITION: the vertical position. */
  int32_t y;

  /** WINDOW_STATE: whether the window is iconified. */
  bool iconified;

  /**
   * WINDOW_TITLE and ICON_LABEL: the UTF-8 text. It must hold no control
   * codepoint (C0, DEL or C1), or the encoding fails with
   * GHOSTTY_INVALID_VALUE. CLIPBOARD: the raw bytes, which are base64
   * encoded.
   */
  GhosttyString text;

  /**
   * CLIPBOARD: the selection of the request, characters from
   * `c p q s 0 1 2 3 4 5 6 7`. Another character fails the encoding with
   * GHOSTTY_INVALID_VALUE.
   */
  GhosttyString selection;

  /** CLIPBOARD: the terminator of the request. */
  GhosttyOscTerminator terminator;
} GhosttyQueryReply;

/**
 * Encode a reply into a caller buffer.
 *
 * @param reply The reply (must not be NULL)
 * @param buf Output buffer, or NULL to ask for the size
 * @param buf_len Size of the buffer in bytes
 * @param[out] out_written The bytes written, or the bytes needed when the
 *             result is GHOSTTY_OUT_OF_SPACE (must not be NULL)
 * @return GHOSTTY_SUCCESS, GHOSTTY_OUT_OF_SPACE if the buffer is too small,
 *         or GHOSTTY_INVALID_VALUE for a bad kind, field, size or argument
 */
GHOSTTY_API GhosttyResult ghostty_query_reply_encode(
    const GhosttyQueryReply* reply,
    char* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_QUERY_REPLY_H */
