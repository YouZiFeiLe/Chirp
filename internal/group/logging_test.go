package group

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

func TestPhaseLogsMatchReturnedRevisionAndExcludeMLSMaterial(t *testing.T) {
	var output bytes.Buffer
	h := NewHub(store.DefaultRoomID, DefaultPolicy(), slog.New(slog.NewJSONHandler(&output, nil)))
	p := peer("member_test")
	var snapshot Snapshot
	for _, operation := range []string{"join", "package", "publish", "ack"} {
		output.Reset()
		request := roundRequest(snapshot, operation)
		if operation == "package" {
			request.KeyPackage = publicBlob(128)
		}
		if operation == "publish" || operation == "ack" {
			request.Confirmation = publicBlob(32)
		}
		snapshot = apply(t, h, p, request)
		var record map[string]any
		if err := json.Unmarshal(bytes.TrimSpace(output.Bytes()), &record); err != nil {
			t.Fatal("missing or malformed phase log", operation, output.String(), err)
		}
		if record["phase"] != snapshot.Phase || record["generation"] != float64(snapshot.Generation) || record["revision"] != float64(snapshot.Revision) {
			t.Fatal("phase log disagrees with published state", operation, record, snapshot.Phase, snapshot.Revision)
		}
		if strings.Contains(output.String(), publicBlob(32)) || strings.Contains(output.String(), publicBlob(128)) {
			t.Fatal("MLS payload appeared in phase logs", operation)
		}
	}
}
