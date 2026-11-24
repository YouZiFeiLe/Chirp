package room

import (
	"context"
	"errors"
	"time"

	"github.com/livekit/protocol/auth"
	"github.com/livekit/protocol/livekit"
	lksdk "github.com/livekit/server-sdk-go/v2"
	"github.com/twitchtv/twirp"

	"gitlab.youzifeile.cn/chirp/chirp-go/internal/store"
)

type Participant struct {
	ID          string `json:"id"`
	DisplayName string `json:"display_name"`
}

type Backend interface {
	Participants(context.Context, string) ([]Participant, error)
	EnsureRoom(context.Context, string) error
}

type AdminBackend interface {
	Participants(context.Context, string) ([]Participant, error)
	RemoveParticipant(context.Context, string, string) error
	EndRoom(context.Context, string) error
}

type Service struct{ client *lksdk.RoomServiceClient }

func New(url, key, secret string) *Service {
	return &Service{client: lksdk.NewRoomServiceClient(url, key, secret)}
}

func (s *Service) Participants(ctx context.Context, name string) ([]Participant, error) {
	response, err := s.client.ListParticipants(ctx, &livekit.ListParticipantsRequest{Room: name})
	var twirpErr twirp.Error
	if errors.As(err, &twirpErr) && twirpErr.Code() == twirp.NotFound {
		return []Participant{}, nil
	}
	if err != nil {
		return nil, err
	}
	participants := make([]Participant, 0, len(response.Participants))
	for _, p := range response.Participants {
		participants = append(participants, Participant{ID: p.Identity, DisplayName: p.Name})
	}
	return participants, nil
}

func (s *Service) EnsureRoom(ctx context.Context, name string) error {
	_, err := s.client.CreateRoom(ctx, &livekit.CreateRoomRequest{Name: name, EmptyTimeout: 300})
	return err
}

func (s *Service) RemoveParticipant(ctx context.Context, name, identity string) error {
	_, err := s.client.RemoveParticipant(ctx, &livekit.RoomParticipantIdentity{Room: name, Identity: identity})
	return ignoreNotFound(err)
}

func (s *Service) EndRoom(ctx context.Context, name string) error {
	_, err := s.client.DeleteRoom(ctx, &livekit.DeleteRoomRequest{Room: name})
	return ignoreNotFound(err)
}

func ignoreNotFound(err error) error {
	var twirpErr twirp.Error
	if errors.As(err, &twirpErr) && twirpErr.Code() == twirp.NotFound {
		return nil
	}
	return err
}

type Issuer struct {
	APIKey    string
	APISecret string
	TTL       time.Duration
}

func (i Issuer) Issue(member store.Member, admission store.RoomAdmission) (string, time.Time, error) {
	grant := &auth.VideoGrant{RoomJoin: true, Room: admission.RoomID}
	grant.SetCanPublish(true)
	grant.SetCanSubscribe(true)
	grant.SetCanPublishData(true)
	grant.SetCanPublishSources([]livekit.TrackSource{livekit.TrackSource_MICROPHONE})
	// Room members announce their own playback switch through a LiveKit attribute.
	grant.SetCanUpdateOwnMetadata(true)
	token, err := auth.NewAccessToken(i.APIKey, i.APISecret).
		SetIdentity(admission.Identity()).SetName(member.DisplayName).
		SetValidFor(i.TTL).SetVideoGrant(grant).ToJWT()
	return token, time.Now().UTC().Add(i.TTL).Truncate(time.Second), err
}
