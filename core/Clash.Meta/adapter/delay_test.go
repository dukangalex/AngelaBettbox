package adapter

import (
	"testing"
	"time"
)

func TestSuccessfulDelayPreservesNonzeroSubmillisecond(t *testing.T) {
	tests := []struct {
		duration time.Duration
		want     uint16
	}{
		{0, 1}, {time.Nanosecond, 1}, {999 * time.Microsecond, 1},
		{time.Millisecond, 1}, {1500 * time.Microsecond, 1},
		{2 * time.Millisecond, 2}, {30 * time.Second, 30000},
	}
	for _, tc := range tests {
		if got := successfulDelay(tc.duration); got != tc.want {
			t.Errorf("successfulDelay(%s) = %d, want %d", tc.duration, got, tc.want)
		}
	}
}
