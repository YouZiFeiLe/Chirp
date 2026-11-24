package config

import (
	"testing"
	"time"
)

func TestGroupRotationValidation(t *testing.T) {
	setDatabaseEnv(t)
	c, err := Load()
	if err != nil || c.GroupRotation != time.Minute {
		t.Fatal(c, err)
	}
	for _, value := range []string{"0", "1s", "31m", "invalid"} {
		t.Setenv("CHIRP_GROUP_ROTATION", value)
		if _, err := Load(); err == nil {
			t.Fatal("unsafe rotation accepted", value)
		}
	}
}
