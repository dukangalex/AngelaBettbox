package statistic

import (
	"sync"
	"testing"
)

// Exercise the same manager through the /memory and /connections APIs at once.
func TestMemoryAndSnapshotConcurrent(t *testing.T) {
	m := DefaultManager
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(snapshot bool) {
			defer wg.Done()
			<-start
			for n := 0; n < 30; n++ {
				if snapshot {
					_ = m.Snapshot().Memory
				} else {
					_ = m.Memory()
				}
			}
		}(i%2 == 0)
	}
	close(start)
	wg.Wait()
}

func TestMemoryReadingsRemainAvailable(t *testing.T) {
	if got := DefaultManager.Memory(); got == 0 {
		t.Fatal("Memory returned zero")
	}
	if got := DefaultManager.Snapshot().Memory; got == 0 {
		t.Fatal("Snapshot.Memory returned zero")
	}
}
