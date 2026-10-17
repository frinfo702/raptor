// Raptor client: talk to a rap server and show its blocks in libghostty
// surfaces.
//
// A client is one connection to the server. It makes JSON control
// requests, delivers events, and binds blocks to surfaces: a bound
// surface gets the block's output straight from the client's reader
// thread, and its input, size and focus go back to the block. When the
// connection drops, the client reconnects and resumes every bound block
// where it left off.
//
// Call ghostty_init first. Strings this API returns are allocated with
// malloc; release them with free.

#ifndef RAPTOR_H
#define RAPTOR_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ghostty.h"

typedef struct rap_client_s* rap_client_t;
typedef struct rap_mirror_s* rap_mirror_t;

// Gets each event as a JSON object, e.g. {"event":"title_changed",...}.
// Events come after a "session.subscribe" request, and the client adds
// {"event":"server_disconnected"} and {"event":"server_reconnected"}.
// It runs on the client's reader thread and must not call
// rap_client_request, bind or unbind.
typedef void (*rap_event_cb)(void* userdata, const char* json);

// Connect to the server listening on socket_path, or on a tailnet node
// given as host[:port] (rap -S takes the same). If socket_path is NULL,
// use $RAP_SERVER or the per-user default socket. Never starts a server.
// Returns NULL if there is no server.
GHOSTTY_API rap_client_t rap_client_connect(const char* socket_path);

// The online macOS and Linux machines on this machine's tailnet, other
// than this one, as JSON:
// {"peers":[{"name":"box","dns":"box.tail1.ts.net","rap":"running"}]}.
// "rap" is "running" if a rap server answers on the machine's default
// port, "refused" if one answers but won't let this machine in, and
// "none" otherwise. Asks every machine at once and takes up to a couple
// of seconds. Returns NULL if Tailscale isn't running here.
GHOSTTY_API char* rap_tailnet_peers(void);

// Disconnect. Free surfaces bound to the client first.
GHOSTTY_API void rap_client_free(rap_client_t);

GHOSTTY_API void rap_client_set_event_callback(rap_client_t,
                                                rap_event_cb,
                                                void* userdata);

// Send a request, {"method":"session.list","params":{}}, and wait for the
// response: {"id":1,"result":{...}} or {"id":1,"error":{...}}. The client
// sets the id. Returns NULL if the request isn't a JSON object with a
// method, or the connection is down.
GHOSTTY_API char* rap_client_request(rap_client_t, const char* json);

// Set a surface config's I/O so that a surface created from it can be
// bound to a block: io_mode becomes external and the io callbacks go to
// this client.
GHOSTTY_API void rap_client_surface_config(rap_client_t,
                                            ghostty_surface_config_s*);

// Show the block (its id, or anything else block.subscribe takes) in a
// surface created from rap_client_surface_config, replacing what it
// showed. Returns false if the server has no such block. The surface
// hears that the block's program exited only while the client has a
// session.subscribe covering the block's session.
GHOSTTY_API bool rap_client_bind(rap_client_t,
                                 const char* block,
                                 ghostty_surface_t);

// Stop showing a block in the surface. Its input goes nowhere until it is
// bound again.
GHOSTTY_API void rap_client_unbind(rap_client_t, ghostty_surface_t);

// Make the client the size owner of the surface's block, as focusing the
// surface does. For a surface that kept its focus while another window had
// the keyboard.
GHOSTTY_API void rap_client_claim(rap_client_t, ghostty_surface_t);

// A mirror is a headless surface: a terminal with no view, for tools and
// tests.
GHOSTTY_API rap_mirror_t rap_mirror_new(void);

// Free a mirror. Unbind it first.
GHOSTTY_API void rap_mirror_free(rap_mirror_t);

GHOSTTY_API bool rap_client_bind_mirror(rap_client_t,
                                        const char* block,
                                        rap_mirror_t);
GHOSTTY_API void rap_client_unbind_mirror(rap_client_t, rap_mirror_t);

// The mirror's screen and scrollback as plain text, like the response to
// block.method "format" with "scope":"all". NULL until it has loaded
// the block.
GHOSTTY_API char* rap_mirror_text(rap_mirror_t);

#ifdef __cplusplus
}
#endif

#endif /* RAPTOR_H */
