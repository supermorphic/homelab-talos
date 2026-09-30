package kubesecrets

import (
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hashicorp/go-secure-stdlib/fileutil"
	"github.com/openbao/openbao/sdk/v2/logical"
)

// Exercise the cached backend client against an independent HTTP authorization
// oracle. All credentials are synthetic; no Kubernetes cluster is involved.
func TestLocalTokenRotationKeepsIssuing(t *testing.T) {
	var expected atomic.Value
	expected.Store("synthetic-token-a")
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer "+expected.Load().(string) {
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]any{"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "Unauthorized", "code": 401})
			return
		}
		if r.Method != "POST" || r.URL.Path != "/api/v1/namespaces/synthetic/serviceaccounts/reader/token" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"apiVersion": "authentication.k8s.io/v1", "kind": "TokenRequest", "status": map[string]any{"token": "synthetic-issued", "expirationTimestamp": time.Now().Add(time.Minute).UTC().Format(time.RFC3339)}})
	}))
	defer server.Close()

	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("synthetic-token-a"), 0600); err != nil {
		t.Fatal(err)
	}
	b, storage := getTestBackend(t)
	// Zero cache TTL avoids a wall-clock wait; production retains its one-minute
	// file-reader cache. The tested backend client cache is unchanged.
	b.localSATokenReader = fileutil.NewCachingFileReader(path, 0)
	ca := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}))
	entry, err := logical.StorageEntryJSON(configPath, &kubeConfig{Host: server.URL, CACert: ca})
	if err != nil {
		t.Fatal(err)
	}
	if err := storage.Put(t.Context(), entry); err != nil {
		t.Fatal(err)
	}
	issue := func() error {
		c, err := b.getClient(t.Context(), storage)
		if err != nil {
			return err
		}
		_, err = c.createToken(t.Context(), "synthetic", "reader", time.Minute, []string{"synthetic-audience"})
		return err
	}
	if err := issue(); err != nil {
		t.Fatalf("initial issuance: %v", err)
	}
	expected.Store("synthetic-token-b")
	if err := os.WriteFile(path+".new", []byte("synthetic-token-b"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path+".new", path); err != nil {
		t.Fatal(err)
	}
	if err := issue(); err != nil {
		t.Fatalf("issuance after token rotation: %v", err)
	}
}
