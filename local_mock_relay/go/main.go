// Command relay is the Go implementation of local_mock's relay host.
//
// Usage: relay [port]
//
// Environment:
//
//	LOCAL_MOCK_HOST           listen address (default 127.0.0.1; use 0.0.0.0 in containers)
//	LOCAL_MOCK_WEB_DIR        console files (default build/web)
//	LOCAL_MOCK_PING_SECONDS   WebSocket ping interval (default 5)
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"mime"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func (r *Relay) serveWeb(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet && req.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	root, err := filepath.EvalSymlinks(r.webDir)
	if err == nil {
		root, err = filepath.Abs(root)
	}
	if err != nil {
		http.NotFound(w, req)
		return
	}
	name := "index.html"
	if req.URL.Path != "/" {
		name = strings.TrimPrefix(filepath.FromSlash(filepath.Clean("/"+req.URL.Path)), string(filepath.Separator))
	}
	resolved, err := filepath.EvalSymlinks(filepath.Join(root, name))
	if err != nil || !strings.HasPrefix(resolved, root+string(filepath.Separator)) {
		http.NotFound(w, req)
		return
	}
	f, err := os.Open(resolved)
	if err != nil {
		http.NotFound(w, req)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.IsDir() {
		http.NotFound(w, req)
		return
	}
	if t := mime.TypeByExtension(filepath.Ext(resolved)); t != "" {
		w.Header().Set("Content-Type", t)
	} else {
		w.Header().Set("Content-Type", "application/octet-stream")
	}
	w.Header().Set("Cache-Control", "no-store")
	http.ServeContent(w, req, "", time.Time{}, f)
}

func main() {
	port := 9090
	if v := os.Getenv("LOCAL_MOCK_PORT"); v != "" {
		port, _ = strconv.Atoi(v)
	}
	if len(os.Args) > 1 {
		p, err := strconv.Atoi(os.Args[1])
		if err != nil || len(os.Args) > 2 {
			port = 0
		} else {
			port = p
		}
	}
	if port < 1 || port > 65535 {
		fmt.Fprintln(os.Stderr, "Usage: relay [port]")
		os.Exit(64)
	}
	host := envOr("LOCAL_MOCK_HOST", "127.0.0.1")
	webDir := envOr("LOCAL_MOCK_WEB_DIR", "build/web")
	ping := 5 * time.Second
	if v, err := strconv.ParseFloat(os.Getenv("LOCAL_MOCK_PING_SECONDS"), 64); err == nil && v > 0 {
		ping = time.Duration(v * float64(time.Second))
	}
	if st, err := os.Stat(webDir); err != nil || !st.IsDir() {
		fmt.Fprintln(os.Stderr, "Web files not found. Run flutter build web first.")
		os.Exit(66)
	}

	relay := NewRelay(webDir, ping)
	ln, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		if errors.Is(err, syscall.EADDRINUSE) {
			fmt.Fprintf(os.Stderr, "Port %d is already in use. Stop the process or choose another port.\n", port)
			os.Exit(98)
		}
		log.Fatal(err)
	}
	srv := &http.Server{Handler: relay.Handler(), ReadHeaderTimeout: 10 * time.Second}
	fmt.Printf("Local Mock: http://%s:%d\n", host, port)
	log.Printf("relay instance=%s hostname=%s pid=%d ping=%s", relay.info.Instance, relay.info.Hostname, relay.info.PID, ping)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		s := <-sig
		log.Printf("received signal %v, shutting down", s)
		relay.Shutdown("Relay shutting down (" + s.String() + ")")
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
