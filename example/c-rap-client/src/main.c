#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <raptor.h>

// The string value of the first "key" in a JSON response, unescaped, or
// NULL. Enough for the ASCII responses this example reads.
static char *json_string(const char *json, const char *key) {
  char pattern[64];
  snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
  const char *p = strstr(json, pattern);
  if (p == NULL) return NULL;
  p += strlen(pattern);

  char *out = malloc(strlen(p) + 1);
  size_t n = 0;
  for (; *p != '\0' && *p != '"'; p++) {
    if (*p != '\\') {
      out[n++] = *p;
      continue;
    }
    p++;
    switch (*p) {
      case 'n': out[n++] = '\n'; break;
      case 't': out[n++] = '\t'; break;
      case 'r': out[n++] = '\r'; break;
      case 'u': {
        unsigned v = 0;
        sscanf(p + 1, "%4x", &v);
        out[n++] = (char)v;
        p += 4;
        break;
      }
      default: out[n++] = *p; break;
    }
  }
  out[n] = '\0';
  return out;
}

// Send a request and print a failure.
static char *request(rap_client_t client, const char *json) {
  char *resp = rap_client_request(client, json);
  if (resp == NULL || strstr(resp, "\"error\"") != NULL) {
    fprintf(stderr, "request failed: %s -> %s\n", json, resp ? resp : "(null)");
  }
  return resp;
}

extern char **environ;

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <path to rap>\n", argv[0]);
    return 2;
  }
  if (ghostty_init((uintptr_t)argc, argv) != 0) return 1;

  // A test server on a private socket.
  char socket[64];
  snprintf(socket, sizeof socket, "/tmp/c-rap-client-%d.sock", (int)getpid());
  char *server_argv[] = {argv[1], "server", "run", "-S", socket, NULL};
  pid_t server;
  if (posix_spawn(&server, argv[1], NULL, NULL, server_argv, environ) != 0) return 1;
  for (int i = 0; i < 400 && access(socket, F_OK) != 0; i++) usleep(25 * 1000);

  rap_client_t client = rap_client_connect(socket);
  if (client == NULL) {
    fprintf(stderr, "no rap server\n");
    return 1;
  }

  char *resp = request(client, "{\"method\":\"session.list\",\"params\":{}}");
  printf("sessions: %s\n", resp);
  free(resp);

  // A block that prints 1000 lines when it reads a line.
  resp = request(client,
      "{\"method\":\"session.create\",\"params\":{\"label\":\"c-rap-client\","
      "\"cols\":80,\"rows\":24,\"command\":[\"/bin/sh\",\"-c\","
      "\"read x; i=1; while [ $i -le 1000 ]; do echo \\\"line $i\\\"; "
      "i=$((i+1)); done; exec cat\"]}}");
  char *block = resp ? json_string(resp, "block") : NULL;
  free(resp);
  if (block == NULL) return 1;
  printf("block: %s\n", block);

  // Show the block in a headless surface, then start the output.
  rap_mirror_t mirror = rap_mirror_new();
  if (!rap_client_bind_mirror(client, block, mirror)) return 1;
  char json[512];
  snprintf(json, sizeof json,
      "{\"method\":\"block.method\",\"params\":{\"block\":\"%s\","
      "\"method\":\"write\",\"data\":\"go\\n\"}}", block);
  free(request(client, json));

  // Wait until the surface shows exactly what the server captures.
  snprintf(json, sizeof json,
      "{\"method\":\"block.method\",\"params\":{\"block\":\"%s\","
      "\"method\":\"format\",\"scope\":\"all\"}}", block);
  bool matched = false;
  for (int i = 0; i < 1000 && !matched; i++) {
    resp = request(client, json);
    char *capture = resp ? json_string(resp, "text") : NULL;
    char *text = rap_mirror_text(mirror);
    matched = capture != NULL && text != NULL &&
              strstr(capture, "line 1000") != NULL &&
              strcmp(capture, text) == 0;
    free(text);
    free(capture);
    free(resp);
    if (!matched) usleep(10 * 1000);
  }
  printf(matched ? "surface matches the server's capture\n"
                 : "surface does not match the server's capture\n");

  rap_client_unbind_mirror(client, mirror);
  rap_mirror_free(mirror);

  free(request(client, "{\"method\":\"server.stop\",\"params\":{}}"));
  rap_client_free(client);
  waitpid(server, NULL, 0);
  char lock[80];
  snprintf(lock, sizeof lock, "%s.lock", socket);
  unlink(lock);
  free(block);
  return matched ? 0 : 1;
}
