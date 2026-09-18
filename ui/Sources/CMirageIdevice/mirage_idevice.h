/*
 * The crate's header, included rather than copied.
 *
 * This used to be a copy that ./scripts/build-native.sh refreshed. That meant a build run
 * without the script first compiled cleanly against a stale header and then failed on
 * whichever symbol was new — a confusing failure a long way from its cause. Including the
 * real thing makes drift impossible.
 */
#include "../../../native/mirage-idevice/include/mirage_idevice.h"
