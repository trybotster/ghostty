/**
 * @file terminfo.h
 *
 * Terminfo - the identity and the terminfo source of the emulator.
 */

#ifndef GHOSTTY_VT_TERMINFO_H
#define GHOSTTY_VT_TERMINFO_H

/** @defgroup terminfo Terminfo
 *
 * The terminfo entry that describes the capabilities that libghostty-vt
 * implements, for a host that sets TERM for the programs it runs and that
 * installs the entry with `tic`.
 *
 * The entry is the one that `ghostty +terminfo` prints, rendered when
 * libghostty-vt is built. Nothing is parsed or copied at run time.
 *
 * @{
 */

#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * The name that a program reads from the TERM environment variable: the
 * first name of the entry ("xterm-ghostty").
 *
 * The string is NUL terminated past its length and valid for the life of the
 * process.
 *
 * @param[out] out The name (must not be NULL)
 */
GHOSTTY_API void ghostty_terminfo_name(GhosttyString* out);

/**
 * The terminfo source text of the entry, as `tic` reads it.
 *
 * The string is NUL terminated past its length and valid for the life of the
 * process.
 *
 * @param[out] out The source text (must not be NULL)
 */
GHOSTTY_API void ghostty_terminfo_source(GhosttyString* out);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_TERMINFO_H */
