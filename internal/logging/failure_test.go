package logging

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
)

func TestBackgroundFailureIsVisibleDeduplicatedAndRecoveryCounted(t *testing.T) {
	var output bytes.Buffer
	tracker := FailureTracker{Logger: slog.New(slog.NewJSONHandler(&output, nil)), Event: "group.authority"}
	for range 50 {
		tracker.Observe(context.Background(), errors.New("database locked"))
	}
	tracker.Observe(context.Background(), nil)
	tracker.Observe(context.Background(), nil)
	if strings.Count(output.String(), "group.authority.failed") != 1 || strings.Count(output.String(), "group.authority.recovered") != 1 || !strings.Contains(output.String(), `"failed_checks":50`) {
		t.Fatal("outage spammed or recovery missing", output.String())
	}
}
