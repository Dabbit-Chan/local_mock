package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// peer wraps one WebSocket (an app or a console) and records everything we
// need to explain, afterwards, why it went away.
type peer struct {
	id        int64
	role      string // "app" | "console"
	conn      *websocket.Conn
	remote    string
	proxy     map[string]string // forwarding headers seen on the upgrade request
	startedAt time.Time

	writeMu sync.Mutex

	initialized atomic.Bool
	deviceID    atomic.Value // string

	msgsIn     atomic.Int64
	msgsOut    atomic.Int64
	pingsSent  atomic.Int64
	pongsRecv  atomic.Int64
	lastReadAt atomic.Int64 // unix nano
	lastPongAt atomic.Int64

	localReason atomic.Value // string; set when *we* closed the socket
	finished    atomic.Bool
}

var proxyHeaders = []string{
	"X-Forwarded-For", "X-Forwarded-Proto", "X-Real-IP", "Via", "Forwarded",
	"X-Request-Id", "User-Agent", "Connection", "Upgrade",
}

func newPeer(id int64, role string, conn *websocket.Conn, req *http.Request) *peer {
	p := &peer{
		id:        id,
		role:      role,
		conn:      conn,
		remote:    req.RemoteAddr,
		proxy:     map[string]string{},
		startedAt: time.Now(),
	}
	for _, h := range proxyHeaders {
		if v := req.Header.Get(h); v != "" {
			p.proxy[h] = v
		}
	}
	p.lastReadAt.Store(time.Now().UnixNano())
	return p
}

func (p *peer) device() string {
	v, _ := p.deviceID.Load().(string)
	return v
}

func (p *peer) send(msg map[string]any) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	p.writeMu.Lock()
	_ = p.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	err = p.conn.WriteMessage(websocket.TextMessage, data)
	p.writeMu.Unlock()
	if err != nil {
		// A write failure means the path is broken; let the read loop notice
		// and record it, but make sure it wakes up.
		p.localReason.CompareAndSwap(nil, "write failed: "+err.Error())
		_ = p.conn.Close()
		return
	}
	p.msgsOut.Add(1)
}

// closeWith sends a close frame (so the browser sees code+reason) and makes
// the read loop exit shortly after.
func (p *peer) closeWith(code int, reason string) {
	p.localReason.CompareAndSwap(nil, fmt.Sprintf("closed by relay: %d %s", code, reason))
	p.writeMu.Lock()
	_ = p.conn.WriteControl(websocket.CloseMessage,
		websocket.FormatCloseMessage(code, reason), time.Now().Add(time.Second))
	p.writeMu.Unlock()
	_ = p.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
}

// pingLoop keeps traffic flowing on otherwise idle connections. Many proxies
// drop a WebSocket that is silent for a while; control frames count as traffic.
func (p *peer) pingLoop(interval time.Duration, stop <-chan struct{}) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			p.writeMu.Lock()
			err := p.conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second))
			p.writeMu.Unlock()
			if err != nil {
				return
			}
			p.pingsSent.Add(1)
		}
	}
}

// classify turns a read error into a human sentence plus close code.
func (p *peer) classify(err error) (code int, kind, detail string) {
	if v, _ := p.localReason.Load().(string); v != "" {
		return 0, "relay-closed", v
	}
	var ce *websocket.CloseError
	if errors.As(err, &ce) {
		if ce.Code == websocket.CloseAbnormalClosure {
			return ce.Code, "abnormal",
				"TCP 连接在没有 WebSocket close 帧的情况下断开（对端进程退出 / 中间代理或 LB 直接断 TCP / 网络重置）"
		}
		return ce.Code, "peer-close", fmt.Sprintf("对端发送了 close 帧：%d %q", ce.Code, ce.Text)
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return 0, "read-timeout",
			"超过读超时没有收到任何数据或 pong（连接静默死亡：对端无响应，或中间设备吞掉了数据）"
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return 1006, "eof", "读到 EOF，对端或代理关闭了 TCP 连接"
	}
	return 0, "error", err.Error()
}

type disconnect struct {
	At          string            `json:"at"`
	PeerID      int64             `json:"peerId"`
	Role        string            `json:"role"`
	DeviceID    string            `json:"deviceId,omitempty"`
	Remote      string            `json:"remote"`
	Proxy       map[string]string `json:"proxy,omitempty"`
	Handshaken  bool              `json:"handshaken"`
	LivedMs     int64             `json:"livedMs"`
	Kind        string            `json:"kind"`
	CloseCode   int               `json:"closeCode,omitempty"`
	Detail      string            `json:"detail"`
	MsgsIn      int64             `json:"msgsIn"`
	MsgsOut     int64             `json:"msgsOut"`
	PingsSent   int64             `json:"pingsSent"`
	PongsRecv   int64             `json:"pongsRecv"`
	SinceReadMs int64             `json:"sinceLastReadMs"`
	SincePongMs int64             `json:"sinceLastPongMs"`
}

func (p *peer) record(err error) disconnect {
	code, kind, detail := p.classify(err)
	now := time.Now()
	d := disconnect{
		At:          now.UTC().Format(time.RFC3339Nano),
		PeerID:      p.id,
		Role:        p.role,
		DeviceID:    p.device(),
		Remote:      p.remote,
		Proxy:       p.proxy,
		Handshaken:  p.initialized.Load(),
		LivedMs:     now.Sub(p.startedAt).Milliseconds(),
		Kind:        kind,
		CloseCode:   code,
		Detail:      detail,
		MsgsIn:      p.msgsIn.Load(),
		MsgsOut:     p.msgsOut.Load(),
		PingsSent:   p.pingsSent.Load(),
		PongsRecv:   p.pongsRecv.Load(),
		SinceReadMs: now.Sub(time.Unix(0, p.lastReadAt.Load())).Milliseconds(),
	}
	if t := p.lastPongAt.Load(); t != 0 {
		d.SincePongMs = now.Sub(time.Unix(0, t)).Milliseconds()
	} else {
		d.SincePongMs = -1
	}
	return d
}

func asJSON(r io.Reader) (map[string]any, error) {
	dec := json.NewDecoder(r)
	dec.UseNumber()
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		return nil, err
	}
	return m, nil
}

func parse(raw []byte) (map[string]any, error) { return asJSON(bytes.NewReader(raw)) }
