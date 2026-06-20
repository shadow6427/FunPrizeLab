package analytics

import (
	"context"
	"sync"
	"testing"
	"time"
)

func TestCollector_RepeatedStart(t *testing.T) {
	c := NewCollector()
	ctx := context.Background()

	c.Start(ctx)
	c.Start(ctx)

	c.mu.RLock()
	if !c.running {
		t.Errorf("Expected collector to be running")
	}
	c.mu.RUnlock()

	c.Stop()
}

func TestCollector_ConcurrentStart(t *testing.T) {
	c := NewCollector()
	ctx := context.Background()

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.Start(ctx)
		}()
	}
	wg.Wait()

	c.mu.RLock()
	if !c.running {
		t.Errorf("Expected collector to be running")
	}
	c.mu.RUnlock()

	c.Stop()
}

func TestCollector_StopNonBlocking(t *testing.T) {
	c := NewCollector()
	ctx := context.Background()

	c.Stop()

	c.Start(ctx)
	c.Stop()
	c.Stop()
	c.Stop()

	c.mu.RLock()
	if c.running {
		t.Errorf("Expected collector to be stopped")
	}
	c.mu.RUnlock()
}

func TestCollector_Restart(t *testing.T) {
	c := NewCollector()
	ctx := context.Background()

	c.Start(ctx)
	c.Stop()
	c.Start(ctx)

	c.mu.RLock()
	if !c.running {
		t.Errorf("Expected collector to be running after restart")
	}
	c.mu.RUnlock()

	c.Stop()
}
