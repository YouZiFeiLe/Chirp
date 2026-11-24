package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/authorization"
)

// Authorization maintenance runs offline, without business or media configuration.
func manageAuthorization(args []string, output io.Writer) error {
	flags := flag.NewFlagSet("authorization", flag.ContinueOnError)
	flags.SetOutput(output)
	keyPath := os.Getenv("CHIRP_AUTHORIZATION_KEY_FILE")
	if keyPath == "" {
		keyPath = "/run/secrets/authorization-key"
	}
	keyFile := flags.String("key-file", keyPath, "owner-only Ed25519 seed file")
	generate := flags.Bool("generate-key", false, "create key file exclusively and print public key")
	exportTrust := flags.Bool("export-trust", false, "print public Apple trust configuration")
	verifyTrust := flags.String("verify-trust", "", "require this client configuration to match the signing key")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || (*generate && (*exportTrust || *verifyTrust != "")) || (!*generate && !*exportTrust && *verifyTrust == "") {
		return errors.New("choose -generate-key, -export-trust or -verify-trust; run chirp authorization -h")
	}
	if *generate {
		public, err := authorization.GenerateKeyFile(*keyFile)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(output, base64.StdEncoding.EncodeToString(public))
		return err
	}
	key, err := authorization.ReadKeyFile(*keyFile)
	if err != nil {
		return err
	}
	defer clear(key)
	return manageTrust(key.Public().(ed25519.PublicKey), *verifyTrust, *exportTrust, output)
}
