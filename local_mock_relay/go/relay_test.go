package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func dial(t *testing.T, srv *httptest.Server, role string) *websocket.Conn {
	t.Helper()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/ws/"+role, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func read(t *testing.T, c *websocket.Conn) map[string]any {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
	var m map[string]any
	if err := c.ReadJSON(&m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestRelayFlowAndDiag(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "index.html"), []byte("hi"), 0o644)
	r := NewRelay(dir, time.Second)
	srv := httptest.NewServer(r.Handler())
	defer srv.Close()

	app := dial(t, srv, "app")
	_ = app.WriteJSON(map[string]any{"id": "1", "method": "hello", "args": map[string]any{
		"protocolVersion": 1, "deviceId": "d1", "deviceName": "phone", "sessionId": "s1",
		"state": map[string]any{"rules": []any{}},
	}})
	if m := read(t, app); m["id"] != "1" || m["error"] != nil {
		t.Fatalf("app hello: %v", m)
	}

	con := dial(t, srv, "console")
	_ = con.WriteJSON(map[string]any{"id": "1", "method": "hello", "args": map[string]any{"protocolVersion": 1}})
	m := read(t, con)
	res := m["result"].(map[string]any)
	if len(res["devices"].([]any)) != 1 {
		t.Fatalf("console hello: %v", m)
	}
	read(t, con) // devices broadcast

	// console command is forwarded to the app and answered.
	_ = con.WriteJSON(map[string]any{"id": "2", "method": "command", "args": map[string]any{
		"deviceId": "d1", "method": "getState"}})
	cmd := read(t, app)
	if cmd["method"] != "getState" {
		t.Fatalf("forwarded: %v", cmd)
	}
	_ = app.WriteJSON(map[string]any{"id": cmd["id"], "result": map[string]any{"rules": []any{}}})
	ev := read(t, con) // state broadcast precedes the reply, as in the Dart relay
	if ev["event"] != "state" || ev["rules"] == nil {
		t.Fatalf("state event: %v", ev)
	}
	if got := read(t, con); got["id"] != "2" || got["error"] != nil {
		t.Fatalf("command reply: %v", got)
	}

	// traffic flows to the console
	_ = app.WriteJSON(map[string]any{"event": "traffic", "entries": []any{map[string]any{"revision": 1}}})
	if got := read(t, con); got["event"] != "traffic" {
		t.Fatalf("traffic: %v", got)
	}

	// An unchanged console still receives the offline event after a drop.
	app.UnderlyingConn().Close()
	if got := read(t, con); got["event"] != "devices" || got["devices"].([]any)[0].(map[string]any)["online"] != false {
		t.Fatalf("offline event: %v", got)
	}

	// Diagnostics are available over HTTP, independently of the console protocol.
	resp, err := srv.Client().Get(srv.URL + "/diag")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("diag response: %s, headers=%v", resp.Status, resp.Header)
	}
	var diag struct {
		Server      serverInfo       `json:"server"`
		PingSeconds float64          `json:"pingSeconds"`
		Active      []map[string]any `json:"active"`
		Disconnects []disconnect     `json:"disconnects"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&diag); err != nil {
		t.Fatal(err)
	}
	if diag.Server.Instance != r.info.Instance || diag.PingSeconds != 1 {
		t.Fatalf("diag server: %+v", diag)
	}
	if len(diag.Active) != 1 || diag.Active[0]["role"] != "console" {
		t.Fatalf("diag active: %+v", diag.Active)
	}
	if len(diag.Disconnects) != 1 || diag.Disconnects[0].Role != "app" || diag.Disconnects[0].Kind != "abnormal" || diag.Disconnects[0].CloseCode != 1006 {
		t.Fatalf("diag disconnects: %+v", diag.Disconnects)
	}
}
