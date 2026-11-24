package identity

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"os"
	"testing"

	"golang.org/x/crypto/argon2"
)

func TestRecoveryV1IndependentKnownVector(t *testing.T) {
	data, err := os.ReadFile("testdata/recovery-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var vector map[string]string
	if err = json.Unmarshal(data, &vector); err != nil {
		t.Fatal(err)
	}
	file, err := base64.StdEncoding.DecodeString(vector["file"])
	if err != nil {
		t.Fatal(err)
	}
	if len(file) < 71 || len(file) > 65606 || string(file[:8]) != "CHIRPKEY" ||
		binary.BigEndian.Uint16(file[8:]) != 1 || binary.BigEndian.Uint16(file[10:]) != 1 ||
		binary.BigEndian.Uint32(file[12:]) != 65536 || binary.BigEndian.Uint32(file[16:]) != 3 ||
		binary.BigEndian.Uint16(file[20:]) != 4 || len(file) != 54+int(binary.BigEndian.Uint32(file[50:]))+16 {
		t.Fatal("nonconforming container header")
	}
	key := argon2.IDKey([]byte(vector["password"]), file[22:38], 3, 65536, 4, 32)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	clear, err := gcm.Open(nil, file[38:50], file[54:], file[:54])
	if err != nil || string(clear) != vector["payload"] {
		t.Fatal("cross-language recovery vector mismatch", err)
	}
}
