//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

// detach pone al hijo en su propio grupo de procesos: así se apaga con todos sus hijos (los
// runners de Ollama) y no recibe las señales dirigidas a la app.
func detach(cmd *exec.Cmd, _ bool) { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }

func afterStart(cmd *exec.Cmd, lowPrio bool) {
	if lowPrio {
		_ = syscall.Setpriority(syscall.PRIO_PROCESS, cmd.Process.Pid, 10) // como `nice -n 10`
	}
}

func killTree(pid int) { _ = syscall.Kill(-pid, syscall.SIGTERM) }

func processAlive(pid int) bool { return syscall.Kill(pid, 0) == nil }
