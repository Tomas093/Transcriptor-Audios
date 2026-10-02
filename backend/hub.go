package main

import "sync"

// Event es un mensaje SSE: Data ya viene serializado en JSON (una sola línea).
type Event struct {
	Name string
	Data []byte
}

// Hub reparte eventos a todos los clientes conectados por SSE.
type Hub struct {
	mu   sync.Mutex
	subs map[chan Event]struct{}
}

func NewHub() *Hub { return &Hub{subs: map[chan Event]struct{}{}} }

func (h *Hub) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 256)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.subs, ch)
		h.mu.Unlock()
	}
}

// Publish nunca bloquea: si un cliente va lento se descarta el evento (cada evento de
// sesión lleva el estado completo, así que el siguiente lo corrige).
func (h *Hub) Publish(e Event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- e:
		default:
		}
	}
}
