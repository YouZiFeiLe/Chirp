package httpapi

import (
	"bytes"
	"errors"
	"image"
	"image/color"
	_ "image/jpeg"
	"image/png"
	"math"
)

const avatarSize = 512
const maxAvatarPixels = 32_000_000
const maxAvatarDimension = 8192

var errInvalidAvatar = errors.New("invalid avatar image")
var errAvatarDimensions = errors.New("avatar dimensions exceed limits")

// Inspect dimensions before decoding, then center-crop and re-encode pixels.
// No original EXIF, ancillary chunks, or appended payload is stored or served.
func normalizeAvatar(data []byte) ([]byte, error) {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || (format != "jpeg" && format != "png") {
		return nil, errInvalidAvatar
	}
	if cfg.Width < 1 || cfg.Height < 1 || cfg.Width > maxAvatarDimension || cfg.Height > maxAvatarDimension || int64(cfg.Width)*int64(cfg.Height) > maxAvatarPixels {
		return nil, errAvatarDimensions
	}
	src, decodedFormat, err := image.Decode(bytes.NewReader(data))
	if err != nil || decodedFormat != format || src.Bounds().Dx() != cfg.Width || src.Bounds().Dy() != cfg.Height {
		return nil, errInvalidAvatar
	}
	bounds := src.Bounds()
	side := min(bounds.Dx(), bounds.Dy())
	xStart, yStart := bounds.Min.X+(bounds.Dx()-side)/2, bounds.Min.Y+(bounds.Dy()-side)/2
	dst := image.NewRGBA(image.Rect(0, 0, avatarSize, avatarSize))
	// Bilinear sampling in premultiplied RGBA also preserves transparent PNGs.
	for y := range avatarSize {
		sy := max(0, (float64(y)+0.5)*float64(side)/avatarSize-0.5)
		y0 := int(sy)
		fy := sy - float64(y0)
		for x := range avatarSize {
			sx := max(0, (float64(x)+0.5)*float64(side)/avatarSize-0.5)
			x0 := int(sx)
			fx := sx - float64(x0)
			r0, g0, b0, a0 := src.At(xStart+x0, yStart+y0).RGBA()
			r1, g1, b1, a1 := src.At(xStart+min(x0+1, side-1), yStart+y0).RGBA()
			r2, g2, b2, a2 := src.At(xStart+x0, yStart+min(y0+1, side-1)).RGBA()
			r3, g3, b3, a3 := src.At(xStart+min(x0+1, side-1), yStart+min(y0+1, side-1)).RGBA()
			blend := func(a, b, c, d uint32) uint8 {
				return uint8(math.Round(((float64(a)*(1-fx)+float64(b)*fx)*(1-fy) + (float64(c)*(1-fx)+float64(d)*fx)*fy) / 257))
			}
			dst.SetRGBA(x, y, color.RGBA{R: blend(r0, r1, r2, r3), G: blend(g0, g1, g2, g3), B: blend(b0, b1, b2, b3), A: blend(a0, a1, a2, a3)})
		}
	}
	var output bytes.Buffer
	if err := png.Encode(&output, dst); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}
