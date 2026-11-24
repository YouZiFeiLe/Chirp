package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
)

type trustConfiguration struct {
	PublicKey string `json:"public_key"`
}

// Exported pins are client build inputs. CI verifies the configured server seed
// against them automatically; custom deployments replace both together.
func manageTrust(public ed25519.PublicKey, expectedPath string, export bool, output io.Writer) error {
	entry := trustConfiguration{PublicKey: base64.StdEncoding.EncodeToString(public)}
	if expectedPath != "" {
		file, err := os.Open(expectedPath)
		if err != nil {
			return err
		}
		defer file.Close()
		data, err := io.ReadAll(io.LimitReader(file, 65537))
		if err != nil || len(data) > 65536 {
			return errors.New("invalid client trust configuration size")
		}
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		var expected trustConfiguration
		if decoder.Decode(&expected) != nil || decoder.Decode(new(any)) != io.EOF {
			return errors.New("invalid client trust configuration")
		}
		if expected != entry {
			return errors.New("authorization signing key differs from the client public key; configure both together")
		}
	}
	if export {
		encoder := json.NewEncoder(output)
		encoder.SetIndent("", "  ")
		return encoder.Encode(entry)
	}
	return nil
}
