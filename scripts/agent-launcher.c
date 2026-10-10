// Lanzador mínimo del agente: ejecuta /bin/bash con los argumentos que recibe y espera a que termine.
// Existe para que el permiso «Acceso total al disco» de macOS se le dé a ESTE binario (que compila
// scripts/agent.sh al instalar) y no a /bin/bash, que usan todos los scripts del sistema.
// No hace exec: si reemplazara su imagen por bash, macOS volvería a ver a /bin/bash como responsable.
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static volatile pid_t child = 0;

static void forward(int sig) {
  if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "uso: %s script.sh [args...]\n", argv[0]);
    return 2;
  }
  char *args[argc + 1];
  args[0] = "/bin/bash";
  for (int i = 1; i < argc; i++) args[i] = argv[i];
  args[argc] = NULL;

  signal(SIGTERM, forward);
  signal(SIGINT, forward);
  signal(SIGHUP, forward);

  pid_t pid;
  if (posix_spawn(&pid, "/bin/bash", NULL, NULL, args, environ) != 0) {
    perror("posix_spawn");
    return 127;
  }
  child = pid;
  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) return 1;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}
