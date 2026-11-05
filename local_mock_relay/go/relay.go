package main

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

const (
	protocolVersion = 1
	maxTraffic      = 500
	handshakeWait   = 8 * time.Second
	forwardWait     = 7 * time.Second
)

type device struct {
	id, name, session string
	peer              *peer
	rules             []any
	supportsRecording bool
	traffic           []map[string]any
	busy              bool
	ready             bool
	epoch             int
}

func (d *device) json() map[string]any {
	return map[string]any{
		"id": d.id, "name": d.name, "sessionId": d.session,
		"online": d.peer != nil && d.ready,
	}
}

type pendingReq struct {
	deviceID string
	ch       chan pendingResult
}

type pendingResult struct {
	state map[string]any
	err   error
}

// Relay is an in-memory hub. Each app keeps its own acknowledged rules and a
// bounded traffic history; a console disconnecting never changes app rules.
type Relay struct {
	webDir       string
	pingInterval time.Duration
	readTimeout  time.Duration
	info         serverInfo
	diag         diagLog
	upgrader     websocket.Upgrader

	mu       sync.Mutex
	peers    map[*peer]struct{}
	consoles map[*peer]struct{}
	devices  map[string]*device
	pending  map[string]*pendingReq

	counter atomic.Int64
	peerSeq atomic.Int64
}

func NewRelay(webDir string, ping time.Duration) *Relay {
	return &Relay{
		webDir:       webDir,
		pingInterval: ping,
		readTimeout:  ping*3 + 5*time.Second,
		info:         newServerInfo(),
		upgrader: websocket.Upgrader{
			HandshakeTimeout: 8 * time.Second,
			CheckOrigin:      func(*http.Request) bool { return true },
		},
		peers:    map[*peer]struct{}{},
		consoles: map[*peer]struct{}{},
		devices:  map[string]*device{},
		pending:  map[string]*pendingReq{},
	}
}

func (r *Relay) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws/app", func(w http.ResponseWriter, q *http.Request) { r.serveWS(w, q, "app") })
	mux.HandleFunc("/ws/console", func(w http.ResponseWriter, q *http.Request) { r.serveWS(w, q, "console") })
	mux.HandleFunc("/diag", r.handleDiag)
	mux.HandleFunc("/", r.serveWeb)
	return mux
}

func (r *Relay) serveWS(w http.ResponseWriter, req *http.Request, role string) {
	conn, err := r.upgrader.Upgrade(w, req, nil) // replies 400 itself when not an upgrade
	if err != nil {
		log.Printf("upgrade failed role=%s remote=%s: %v", role, req.RemoteAddr, err)
		return
	}
	conn.SetReadLimit(64 << 20)
	p := newPeer(r.peerSeq.Add(1), role, conn, req)
	r.mu.Lock()
	r.peers[p] = struct{}{}
	r.mu.Unlock()
	log.Printf("connect peer=%d role=%s remote=%s proxy=%v", p.id, role, p.remote, p.proxy)

	extend := func() { _ = conn.SetReadDeadline(time.Now().Add(r.readTimeout)) }
	extend()
	conn.SetPongHandler(func(string) error {
		p.pongsRecv.Add(1)
		p.lastPongAt.Store(time.Now().UnixNano())
		extend()
		return nil
	})
	// The default ping handler would reply with a pong; keep that behaviour but
	// count it as activity too.
	defaultPing := conn.PingHandler()
	conn.SetPingHandler(func(s string) error { extend(); return defaultPing(s) })

	stop := make(chan struct{})
	go p.pingLoop(r.pingInterval, stop)
	hs := time.AfterFunc(handshakeWait, func() {
		if !p.initialized.Load() {
			p.closeWith(websocket.ClosePolicyViolation, "Handshake timeout")
		}
	})

	var readErr error
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			readErr = err
			break
		}
		extend()
		p.lastReadAt.Store(time.Now().UnixNano())
		p.msgsIn.Add(1)
		r.onMessage(p, raw)
	}

	hs.Stop()
	close(stop)
	_ = conn.Close()
	r.onGone(p, readErr)
}

func (r *Relay) onGone(p *peer, err error) {
	if !p.finished.CompareAndSwap(false, true) {
		return
	}
	r.logDisconnect(p.record(err))
	r.mu.Lock()
	delete(r.peers, p)
	delete(r.consoles, p)
	var changed bool
	if id := p.device(); id != "" {
		if d := r.devices[id]; d != nil && d.peer == p {
			d.peer = nil
			d.ready = false
			for k, pr := range r.pending {
				if pr.deviceID == id {
					pr.ch <- pendingResult{err: errors.New("设备已离线")}
					delete(r.pending, k)
				}
			}
			changed = true
		}
	}
	r.mu.Unlock()
	if changed {
		r.broadcastDevices()
	}
}

func asMap(v any) (map[string]any, bool) { m, ok := v.(map[string]any); return m, ok }
func asList(v any) ([]any, bool)         { l, ok := v.([]any); return l, ok }

func asInt(v any) (int64, bool) {
	switch n := v.(type) {
	case interface{ Int64() (int64, error) }:
		i, err := n.Int64()
		return i, err == nil
	case float64:
		return int64(n), true
	}
	return 0, false
}

func (r *Relay) onMessage(p *peer, raw []byte) {
	msg, err := parse(raw)
	if err != nil {
		r.fail(p, nil, fmt.Errorf("invalid JSON: %w", err))
		return
	}
	if !p.initialized.Load() {
		if err := r.hello(p, msg); err != nil {
			r.fail(p, msg["id"], err)
		}
		return
	}
	if p.role == "app" {
		r.appMessage(p, msg)
		return
	}
	// Console commands may block on an app round trip; keep reading meanwhile.
	go func() {
		result, err := r.consoleRequest(msg)
		if err != nil {
			p.send(map[string]any{"id": msg["id"], "error": err.Error()})
			return
		}
		p.send(map[string]any{"id": msg["id"], "result": result})
	}()
}

// fail replies with an error and drops peers that never became usable.
func (r *Relay) fail(p *peer, id any, err error) {
	p.send(map[string]any{"id": id, "error": err.Error()})
	r.mu.Lock()
	notReady := !p.initialized.Load()
	if p.role == "app" && p.initialized.Load() {
		if d := r.devices[p.device()]; d != nil && d.peer == p && !d.ready {
			notReady = true
		}
	}
	r.mu.Unlock()
	if notReady {
		go p.closeWith(websocket.ClosePolicyViolation, "Protocol error")
	}
}

func (r *Relay) hello(p *peer, msg map[string]any) error {
	args, ok := asMap(msg["args"])
	if !ok || msg["method"] != "hello" {
		return errors.New("协议版本不兼容")
	}
	if v, _ := asInt(args["protocolVersion"]); v != protocolVersion {
		return errors.New("协议版本不兼容")
	}
	if p.role == "console" {
		p.initialized.Store(true)
		r.mu.Lock()
		r.consoles[p] = struct{}{}
		devs := r.deviceList()
		r.mu.Unlock()
		p.send(map[string]any{"id": msg["id"], "result": map[string]any{
			"devices": devs,
		}})
		r.broadcastDevices()
		return nil
	}

	id, _ := args["deviceId"].(string)
	name, nameOK := args["deviceName"].(string)
	session, _ := args["sessionId"].(string)
	state, stateOK := asMap(args["state"])
	if id == "" || !nameOK || session == "" || !stateOK {
		return errors.New("Invalid device identity")
	}
	rules, rulesOK := asList(state["rules"])

	r.mu.Lock()
	prev := r.devices[id]
	if prev != nil && prev.peer != nil && prev.session != session {
		r.mu.Unlock()
		return errors.New("设备 ID 已被另一个 App 使用，请设置唯一 deviceId")
	}
	if prev == nil && !rulesOK {
		r.mu.Unlock()
		return errors.New("Invalid app state")
	}
	if prev != nil && prev.peer != nil {
		old := prev.peer
		go old.closeWith(websocket.CloseNormalClosure, "Reconnected")
	}
	d := prev
	if d == nil {
		d = &device{id: id}
		d.rules = append([]any{}, rules...)
	}
	if d.session != session && prev != nil {
		d.traffic = nil
		d.epoch++
	}
	d.name, d.session, d.peer, d.ready = name, session, p, false
	d.supportsRecording = state["supportsRecordingMocks"] == true
	r.devices[id] = d
	p.deviceID.Store(id)
	p.initialized.Store(true)
	restore := d.rules
	r.mu.Unlock()

	p.send(map[string]any{"id": msg["id"], "result": map[string]any{}})
	if prev == nil {
		r.mu.Lock()
		d.ready = true
		r.mu.Unlock()
		r.broadcastDevices()
		return nil
	}
	// Restore only rules acknowledged by an app, never a failed edit. This waits
	// for the app's reply, which arrives on this very socket, so run it aside.
	go func() {
		if _, err := r.forward(d, "replaceRules", map[string]any{"rules": restore}); err != nil {
			r.fail(p, nil, err)
			return
		}
		r.mu.Lock()
		same := d.peer == p
		if same {
			d.ready = true
		}
		r.mu.Unlock()
		if same {
			r.broadcastDevices()
		}
	}()
	return nil
}

func (r *Relay) appMessage(p *peer, msg map[string]any) {
	r.mu.Lock()
	d := r.devices[p.device()]
	if d == nil || d.peer != p {
		r.mu.Unlock()
		return
	}
	if id := msg["id"]; id != nil {
		key := fmt.Sprintf("%s:%v", d.id, id)
		pr := r.pending[key]
		delete(r.pending, key)
		r.mu.Unlock()
		if pr == nil {
			return
		}
		if msg["error"] != nil {
			pr.ch <- pendingResult{err: fmt.Errorf("%v", msg["error"])}
		} else if res, ok := asMap(msg["result"]); ok {
			pr.ch <- pendingResult{state: res}
		} else {
			pr.ch <- pendingResult{err: errors.New("Invalid app state")}
		}
		return
	}
	ev, _ := msg["event"].(string)
	r.mu.Unlock()
	if ev == "traffic" || ev == "snapshot" {
		if entries, ok := asList(msg["entries"]); ok {
			r.appendTraffic(d, entries)
		}
	}
}

func (r *Relay) consoleRequest(msg map[string]any) (map[string]any, error) {
	if msg["method"] != "command" {
		return nil, errors.New("Unknown method")
	}
	args, _ := asMap(msg["args"])
	devID, _ := args["deviceId"].(string)
	r.mu.Lock()
	d := r.devices[devID]
	online := d != nil && d.peer != nil && d.ready
	r.mu.Unlock()
	if !online {
		return nil, errors.New("设备已离线")
	}
	method, _ := args["method"].(string)
	switch method {
	case "getState", "replaceRules", "clear", "clearTraffic":
	default:
		return nil, errors.New("Unknown command")
	}
	inner, _ := asMap(args["args"])
	if inner == nil {
		inner = map[string]any{}
	}
	if _, err := r.forward(d, method, inner); err != nil {
		return nil, err
	}
	r.mu.Lock()
	if method == "clearTraffic" {
		d.traffic = nil
		d.epoch++
	}
	snap := r.snapshot(d)
	r.mu.Unlock()
	ev := map[string]any{"event": "state", "deviceId": d.id}
	for k, v := range snap {
		ev[k] = v
	}
	r.sendConsoles(ev)
	return snap, nil
}

func (r *Relay) forward(d *device, method string, args map[string]any) (map[string]any, error) {
	r.mu.Lock()
	if d.busy {
		r.mu.Unlock()
		return nil, errors.New("设备正在同步，请稍后重试")
	}
	p := d.peer
	if p == nil {
		r.mu.Unlock()
		return nil, errors.New("设备已离线")
	}
	d.busy = true
	id := fmt.Sprintf("relay-%d", r.counter.Add(1))
	key := d.id + ":" + id
	pr := &pendingReq{deviceID: d.id, ch: make(chan pendingResult, 1)}
	r.pending[key] = pr
	r.mu.Unlock()

	defer func() {
		r.mu.Lock()
		delete(r.pending, key)
		d.busy = false
		r.mu.Unlock()
	}()

	p.send(map[string]any{"id": id, "method": method, "args": args})
	var res pendingResult
	select {
	case res = <-pr.ch:
	case <-time.After(forwardWait):
		return nil, errors.New("设备响应超时")
	}
	if res.err != nil {
		return nil, res.err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if d.peer != p {
		return nil, errors.New("设备连接已变化")
	}
	rules, ok := asList(res.state["rules"])
	if !ok {
		return nil, errors.New("Invalid app state")
	}
	d.rules = append([]any{}, rules...)
	d.supportsRecording = res.state["supportsRecordingMocks"] == true
	return res.state, nil
}

// snapshot must be called with r.mu held.
func (r *Relay) snapshot(d *device) map[string]any {
	entries := make([]map[string]any, len(d.traffic))
	copy(entries, d.traffic)
	return map[string]any{
		"rules":                  d.rules,
		"entries":                entries,
		"sessionId":              d.session,
		"epoch":                  d.epoch,
		"supportsRecordingMocks": d.supportsRecording,
	}
}

func (r *Relay) appendTraffic(d *device, entries []any) {
	r.mu.Lock()
	var last int64
	if n := len(d.traffic); n > 0 {
		last, _ = asInt(d.traffic[n-1]["revision"])
	}
	var fresh []map[string]any
	for _, e := range entries {
		m, ok := asMap(e)
		if !ok {
			continue
		}
		if rev, ok := asInt(m["revision"]); ok && rev > last {
			fresh = append(fresh, m)
		}
	}
	if len(fresh) == 0 {
		r.mu.Unlock()
		return
	}
	d.traffic = append(d.traffic, fresh...)
	if len(d.traffic) > maxTraffic {
		d.traffic = append([]map[string]any(nil), d.traffic[len(d.traffic)-maxTraffic:]...)
	}
	ev := map[string]any{
		"event": "traffic", "deviceId": d.id, "sessionId": d.session,
		"epoch": d.epoch, "entries": fresh,
	}
	r.mu.Unlock()
	r.sendConsoles(ev)
}

// deviceList must be called with r.mu held.
func (r *Relay) deviceList() []map[string]any {
	out := make([]map[string]any, 0, len(r.devices))
	for _, d := range r.devices {
		out = append(out, d.json())
	}
	return out
}

func (r *Relay) broadcastDevices() {
	r.mu.Lock()
	ev := map[string]any{"event": "devices", "devices": r.deviceList()}
	r.mu.Unlock()
	r.sendConsoles(ev)
}

func (r *Relay) sendConsoles(ev map[string]any) {
	r.mu.Lock()
	cs := make([]*peer, 0, len(r.consoles))
	for c := range r.consoles {
		cs = append(cs, c)
	}
	r.mu.Unlock()
	for _, c := range cs {
		c.send(ev)
	}
}

func (r *Relay) Shutdown(reason string) {
	r.mu.Lock()
	ps := make([]*peer, 0, len(r.peers))
	for p := range r.peers {
		ps = append(ps, p)
	}
	r.mu.Unlock()
	for _, p := range ps {
		p.closeWith(websocket.CloseGoingAway, reason)
	}
	time.Sleep(300 * time.Millisecond)
}
