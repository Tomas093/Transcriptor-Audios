package main

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Proceso auxiliar: el propio binario de tests hace de «servicio» HTTP cuando FAKE_SERVICE_ADDR está puesto.
func TestMain(m *testing.M) {
	if addr := os.Getenv("FAKE_SERVICE_ADDR"); addr != "" {
		time.Sleep(300 * time.Millisecond) // como un servicio real, tarda un poco en responder
		_ = http.ListenAndServe(addr, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func freeAddr(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}

func TestServiceStartsAndStopsItsOwnProcess(t *testing.T) {
	addr := freeAddr(t)
	s := &ServiceSpec{Name: "fake", Bin: os.Args[0], Env: []string{"FAKE_SERVICE_ADDR=" + addr},
		Health: "http://" + addr + "/", Wait: 10 * time.Second, LowPrio: true, LogDir: t.TempDir()}
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !httpUp(context.Background(), s.Health) {
		t.Fatal("debería responder")
	}
	pid := s.cmd.Process.Pid
	if readPid(filepath.Join(s.LogDir, "fake.pid")) != pid {
		t.Fatal("falta el .pid")
	}
	s.Stop()
	if processAlive(pid) || httpUp(context.Background(), s.Health) {
		t.Fatal("debería haberse apagado")
	}
}

func TestServiceReusesOneAlreadyRunning(t *testing.T) {
	addr := freeAddr(t)
	srv := &http.Server{Addr: addr, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {})}
	l, _ := net.Listen("tcp", addr)
	go srv.Serve(l)
	defer srv.Close()
	s := &ServiceSpec{Name: "fake", Bin: "no-existe", Health: "http://" + addr + "/", Wait: time.Second, LogDir: t.TempDir()}
	if err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	s.Stop() // no es nuestro: no se toca
	if !httpUp(context.Background(), s.Health) || !s.reused {
		t.Fatal("un servicio ajeno no debe apagarse")
	}
}

func TestServiceReportsMissingBinaryAndEarlyExit(t *testing.T) {
	s := &ServiceSpec{Name: "fake", Bin: "no-existe-este-binario", Health: "http://" + freeAddr(t) + "/", Wait: time.Second, LogDir: t.TempDir()}
	if err := s.Start(context.Background()); err == nil {
		t.Fatal("debería fallar sin binario")
	}
	// Un binario que termina enseguida (el de tests sin la variable, filtrando a ningún test).
	s = &ServiceSpec{Name: "fake", Bin: os.Args[0], Args: []string{"-test.run=^$"}, Health: "http://" + freeAddr(t) + "/", Wait: 10 * time.Second, LogDir: t.TempDir()}
	start := time.Now()
	if err := s.Start(context.Background()); err == nil || time.Since(start) > 5*time.Second {
		t.Fatalf("debería avisar enseguida de que terminó: %v", err)
	}
}

func TestLocalAddr(t *testing.T) {
	for addr, want := range map[string]bool{"127.0.0.1:4747": true, "localhost:1": true, "[::1]:2": true, ":4747": false, "0.0.0.0:1": false} {
		if localAddr(addr) != want {
			t.Errorf("%s: quiero %v", addr, want)
		}
	}
}
