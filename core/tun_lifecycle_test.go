package main

import "testing"

func TestTunLifecycleEpochGate(t *testing.T) {
	var state tunLifecycleState
	first := state.begin()
	if !state.canStart(first) {
		t.Fatal("new transition must accept its start")
	}
	if state.running() {
		t.Fatal("transition must keep the gate closed")
	}
	if !state.activate(first) || !state.running() {
		t.Fatal("current successful start must open the gate")
	}

	second := state.begin()
	if second == first || state.running() {
		t.Fatal("new transition must retire the prior running epoch")
	}
	if state.activate(first) || state.stop(first) {
		t.Fatal("stale start/stop must not affect the current epoch")
	}
	if !state.canStart(second) || !state.activate(second) {
		t.Fatal("current epoch must be startable")
	}
	if !state.stop(second) || state.running() || state.canStart(second) {
		t.Fatal("stopped epoch must remain closed and not restart")
	}
}

func TestTunLifecycleStartInvalidatedDuringConstruction(t *testing.T) {
	var state tunLifecycleState
	startEpoch := state.begin()
	if !state.canStart(startEpoch) {
		t.Fatal("start should begin in transition phase")
	}
	stopEpoch := state.begin()
	if state.activate(startEpoch) {
		t.Fatal("retired in-flight start reopened the gate")
	}
	if !state.canStart(stopEpoch) || !state.activate(stopEpoch) {
		t.Fatal("newer epoch should remain independently startable")
	}
}

func TestTunLifecycleTransitionWaitsForInFlightProtection(t *testing.T) {
	var state tunLifecycleState
	epoch := state.begin()
	if !state.activate(epoch) {
		t.Fatal("could not activate test epoch")
	}
	entered := make(chan struct{})
	release := make(chan struct{})
	callbackDone := make(chan struct{})
	go func() {
		state.withRunning(func() bool {
			close(entered)
			<-release
			return true
		})
		close(callbackDone)
	}()
	<-entered
	transitionDone := make(chan uint64, 1)
	go func() { transitionDone <- state.begin() }()
	select {
	case <-transitionDone:
		t.Fatal("transition returned before the admitted protection callback finished")
	default:
	}
	close(release)
	<-callbackDone
	newEpoch := <-transitionDone
	if newEpoch == epoch || state.running() {
		t.Fatal("transition did not retire the prior epoch after callback completion")
	}
}
