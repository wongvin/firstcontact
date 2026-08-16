/*
 * Per-chip identity. The same image is flashed to every board, so the advertised
 * name is derived at runtime from the nRF52840's FICR device ID.
 */

#ifndef SOPHON_IDENT_H
#define SOPHON_IDENT_H

#include <stddef.h>

/* "Sophon-A3F2" + NUL */
#define SOPHON_NAME_MAX 12

/*
 * Writes "Sophon-XXXX" into buf, where XXXX is the low 16 bits of the FICR
 * device ID in uppercase hex. Falls back to the plain "Sophon" if hwinfo is
 * unavailable. Returns 0 on success, or a negative errno if the name did not
 * fit (in which case buf is untouched).
 */
int sophon_device_name(char *buf, size_t len);

#endif /* SOPHON_IDENT_H */
