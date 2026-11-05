package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

const diagKeep = 100

type serverInfo struct {
	Instance  string `json:"instance"`
	Hostname  string `json:"hostname"`
	StartedAt string `json:"startedAt"`
	PID       int    `json:"pid"`
}

// diagLog is a bounded in-memory list of recent disconnects.
type diagLog struct {
	mu    sync.Mutex
	items []disconnect
}

func (d *diagLog) add(x disconnect) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.items = append(d.items, x)
	if len(d.items) > diagKeep {
		d.items = d.items[len(d.items)-diagKeep:]
	}
}

// recent returns newest-first.
func (d *diagLog) recent(n int) []disconnect {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := []disconnect{}
	for i := len(d.items) - 1; i >= 0 && len(out) < n; i-- {
		out = append(out, d.items[i])
	}
	return out
}

func newServerInfo() serverInfo {
	h, _ := os.Hostname()
	return serverInfo{
		Instance:  fmt.Sprintf("%x", time.Now().UnixNano()),
		Hostname:  h,
		StartedAt: time.Now().UTC().Format(time.RFC3339),
		PID:       os.Getpid(),
	}
}

func (r *Relay) logDisconnect(d disconnect) {
	r.diag.add(d)
	log.Printf("disconnect peer=%d role=%s device=%s remote=%s lived=%dms kind=%s code=%d in=%d out=%d pings=%d pongs=%d sinceRead=%dms detail=%s",
		d.PeerID, d.Role, d.DeviceID, d.Remote, d.LivedMs, d.Kind, d.CloseCode,
		d.MsgsIn, d.MsgsOut, d.PingsSent, d.PongsRecv, d.SinceReadMs, d.Detail)
}

// handleDiag serves GET /diag: open it in a browser to see why sockets dropped.
func (r *Relay) handleDiag(w http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	active := []map[string]any{}
	for p := range r.peers {
		active = append(active, map[string]any{
			"peerId": p.id, "role": p.role, "deviceId": p.device(), "remote": p.remote,
			"proxy": p.proxy, "livedMs": time.Since(p.startedAt).Milliseconds(),
			"pingsSent": p.pingsSent.Load(), "pongsRecv": p.pongsRecv.Load(),
		})
	}
	r.mu.Unlock()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(map[string]any{
		"server":      r.info,
		"now":         time.Now().UTC().Format(time.RFC3339Nano),
		"pingSeconds": r.pingInterval.Seconds(),
		"active":      active,
		"disconnects": r.diag.recent(diagKeep),
		"requestSeen": map[string]any{
			"remote":  req.RemoteAddr,
			"host":    req.Host,
			"headers": req.Header,
		},
	})
}
