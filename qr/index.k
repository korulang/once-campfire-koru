// qr — real QR Code generation (byte mode, EC level L) rendered as SVG.
// Used for session-transfer and invite links, matching
// QrCodeController's `RQRCode::QRCode.new(url).as_svg(viewbox: true)`.
import orisha
pub tor svg { text: string } -> string<std/io:allocated!>

// The route-local helpers: /qr_code/<urlsafe-b64> is the path form
// link_to_zoom_qr_code emits (Base64.urlsafe_encode64 of the absolute URL,
// padding kept), and `decode` is the controller's
// Base64.urlsafe_decode64 — bad input answers "" and the route 400s.
pub tor path { url: string } -> string
pub tor decode { enc: string } -> string

// Wrap an SVG string in an orisha:Response (content type + cache headers).
// Consumes the `allocated!` obligation — ownership moves into `res.body` and
// settles when orisha frees an `body_allocated` response body.
pub tor svg-respond { svg: string<std/io:!allocated> } -> orisha:Response
