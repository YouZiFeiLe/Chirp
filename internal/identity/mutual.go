package identity

// MutualRoom is a deterministic public context, not a membership authority.
// Every actual roster entry still needs its certificate and possession proof.
// Device trust is established independently by SAS on each client.
func MutualRoom(origin, roomID string) RoomPolicy {
	return RoomPolicy{Origin: origin, RoomID: roomID, TrustID: Hash(Message("Chirp mutual room v5", origin, roomID)), Version: 1, Members: []string{}, RevokedDevices: []string{}, NotBefore: 1, NotAfter: 253402300799, Signer: Device{Certificates: []Certificate{}}}
}
func (p RoomPolicy) IsMutual() bool { return p.OwnerKey == "" }
