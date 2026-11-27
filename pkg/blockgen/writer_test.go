package blockgen

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/go-kit/log"
)

func TestBlockWritersUseSeparateHeadDirectories(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "blocks")
	first, err := NewTSDBBlockWriter(log.NewNopLogger(), dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = first.close() })
	second, err := NewTSDBBlockWriter(log.NewNopLogger(), dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = second.close() })

	if first.headDir == second.headDir {
		t.Fatal("block writers share a temporary TSDB head directory")
	}
	for _, head := range []string{first.headDir, second.headDir} {
		if filepath.Dir(head) != dir {
			t.Fatalf("head directory %q is outside the block output directory %q", head, dir)
		}
		if _, err := os.Stat(filepath.Join(head, "chunks_head")); err != nil {
			t.Fatal(err)
		}
	}
	if err := first.close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(second.headDir); err != nil {
		t.Fatalf("closing the first writer affected the second head: %v", err)
	}
	if err := second.close(); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("temporary head files remain after close: %v", entries)
	}
}
