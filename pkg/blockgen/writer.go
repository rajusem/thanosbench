package blockgen

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"github.com/oklog/ulid"

	"github.com/go-kit/log"
	"github.com/go-kit/log/level"
	"github.com/pkg/errors"
	"github.com/prometheus/prometheus/model/timestamp"
	"github.com/prometheus/prometheus/storage"
	"github.com/prometheus/prometheus/tsdb"
	"github.com/prometheus/prometheus/tsdb/chunkenc"
)

var _ Writer = &BlockWriter{}

// BlockWriter is implementation of Writer interface. Not designed to be thread-safe.
type BlockWriter struct {
	// logger is given to us as arg.
	logger log.Logger

	// dir is output directory, given to us as arg.
	dir string

	head    *tsdb.Head
	headDir string
}

// NewTSDBBlockWriter creates a single-use writer with its own temporary head.
// The caller is responsible for ensuring that resulting blocks do not overlap.
func NewTSDBBlockWriter(logger log.Logger, dir string) (*BlockWriter, error) {
	dir = filepath.Clean(dir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, errors.Wrap(err, "create block output directory")
	}
	// A new head must not replay mmap chunks from a previously generated block.
	// The profiles can generate blocks newest first, with decreasing timestamps.
	headDir, err := os.MkdirTemp(dir, ".head-*")
	if err != nil {
		return nil, errors.Wrap(err, "create temporary TSDB head directory")
	}
	res := &BlockWriter{
		logger:  logger,
		dir:     dir,
		headDir: headDir,
	}

	if err := res.initHeadAndAppender(); err != nil {
		_ = res.close()
		return nil, err
	}

	return res, nil
}

// Appender is not thread-safe. Returned Appender is thread-save however..
func (w *BlockWriter) Appender(ctx context.Context) storage.Appender {
	return w.head.Appender(ctx)
}

// Flush implements Writer interface. This is where actual block writing
// happens. After flush completes, no write can be done.
func (w *BlockWriter) Flush() (ulid.ULID, error) {
	id, err := w.writeHeadToDisk()
	if err != nil {
		return ulid.ULID{}, errors.Wrap(err, "writeHeadToDisk")
	}

	if err := w.close(); err != nil {
		return ulid.ULID{}, err
	}

	return id, nil
}

func (w *BlockWriter) close() error {
	var headErr error
	if w.head != nil {
		headErr = w.head.Close()
		w.head = nil
	}
	removeErr := os.RemoveAll(w.headDir)
	if removeErr == nil {
		w.headDir = ""
	}
	if headErr != nil {
		return errors.Wrap(headErr, "close head")
	}
	return errors.Wrap(removeErr, "remove temporary TSDB head directory")
}

// initHeadAndAppender creates and initialises new head and appender.
func (w *BlockWriter) initHeadAndAppender() error {
	logger := w.logger

	runtime.GC()

	// Keep Registerer and WAL nil as we don't use them.
	// Not declaring to avoid dependency on github.com/prometheus/client_golang
	//    var r prometheus.Registerer = nil
	//    var w *wal.WAL = nil
	// Put huge chunkRange; It has to be equal then expected block size.
	// Since we don't have info about block size here, set it to large number.
	opts := tsdb.DefaultHeadOptions()
	opts.ChunkRange = durToMilis(9999 * time.Hour)
	opts.ChunkDirRoot = w.headDir
	h, err := tsdb.NewHead(nil, logger, nil, opts, nil)
	if err != nil {
		return errors.Wrap(err, "tsdb.NewHead")
	}

	w.head = h
	// Init to have proper appender.
	return w.head.Init(math.MinInt64)
}

// writeHeadToDisk commits the appender and writes the head to disk.
func (w *BlockWriter) writeHeadToDisk() (ulid.ULID, error) {
	if err := w.Appender(context.TODO()).Commit(); err != nil {
		return ulid.ULID{}, errors.Wrap(err, "appender.Commit")
	}

	seriesCount := w.head.NumSeries()
	if seriesCount == 0 {
		return ulid.ULID{}, errors.New("no series appended; aborting.")
	}

	mint := w.head.MinTime()
	maxt := w.head.MaxTime()
	level.Info(w.logger).Log(
		"msg", "flushing",
		"series_count", seriesCount,
		"mint", timestamp.Time(mint),
		"maxt", timestamp.Time(maxt),
	)
	// Flush head to disk as a block.
	compactor, err := tsdb.NewLeveledCompactor(
		context.Background(),
		nil,
		w.logger,
		[]int64{durToMilis(2 * time.Hour)}, // Does not matter, used only for planning.
		chunkenc.NewPool(),
		nil,
	)
	if err != nil {
		return ulid.ULID{}, errors.Wrap(err, "create leveled compactor")
	}

	return compactor.Write(w.dir, w.head, mint, maxt+1, nil)
}
