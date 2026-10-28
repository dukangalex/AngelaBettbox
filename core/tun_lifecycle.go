package main

import "sync"

type tunLifecyclePhase uint8

const (
	tunLifecycleStopped tunLifecyclePhase = iota
	tunLifecycleTransition
	tunLifecycleRunning
)

// tunLifecycleState serializes epoch changes independently from listener
// construction. Transitioning closes the socket-protection gate immediately;
// an in-flight start can only reopen it if its epoch is still current.
type tunLifecycleState struct {
	mu    sync.Mutex
	epoch uint64
	phase tunLifecyclePhase
}

func (s *tunLifecycleState) begin() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.epoch++
	if s.epoch == 0 { // reserve zero as an invalid/default epoch
		s.epoch++
	}
	s.phase = tunLifecycleTransition
	return s.epoch
}

func (s *tunLifecycleState) canStart(epoch uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return epoch != 0 && epoch == s.epoch && s.phase == tunLifecycleTransition
}

func (s *tunLifecycleState) activate(epoch uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if epoch == 0 || epoch != s.epoch || s.phase != tunLifecycleTransition {
		return false
	}
	s.phase = tunLifecycleRunning
	return true
}

func (s *tunLifecycleState) stop(epoch uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if epoch == 0 || epoch != s.epoch {
		return false
	}
	s.phase = tunLifecycleStopped
	return true
}

func (s *tunLifecycleState) current(epoch uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return epoch != 0 && epoch == s.epoch
}

func (s *tunLifecycleState) withRunning(operation func() bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.phase != tunLifecycleRunning {
		return false
	}
	return operation()
}

func (s *tunLifecycleState) running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.phase == tunLifecycleRunning
}
