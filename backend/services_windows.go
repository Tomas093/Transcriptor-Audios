//go:build windows

package main

import (
	"os/exec"
	"strconv"
	"syscall"
)

const (
	createNoWindow        = 0x08000000
	createNewProcessGroup = 0x00000200
	belowNormalPriority   = 0x00004000
)

// detach: sin ventana de consola y, para Whisper, con prioridad «por debajo de lo normal».
func detach(cmd *exec.Cmd, lowPrio bool) {
	flags := uint32(createNoWindow | createNewProcessGroup)
	if lowPrio {
		flags |= belowNormalPriority
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: flags, HideWindow: true}
}

func afterStart(*exec.Cmd, bool) {}

// killTree apaga el proceso y sus hijos (Windows no tiene grupos de procesos con señales).
func killTree(pid int) {
	c := exec.Command("taskkill", "/PID", strconv.Itoa(pid), "/T", "/F")
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow, HideWindow: true}
	_ = c.Run()
}

func processAlive(pid int) bool {
	h, err := syscall.OpenProcess(syscall.PROCESS_QUERY_INFORMATION, false, uint32(pid))
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)
	var code uint32
	return syscall.GetExitCodeProcess(h, &code) == nil && code == 259 // STILL_ACTIVE
}
