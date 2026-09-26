// Native unit tests for the Windows runner's pure logic. No test framework: a
// tiny no-exception assert counter (so the target can opt out of the runner's
// _HAS_EXCEPTIONS=0 without fighting a framework). Exit code = failure count.
//
// Build + run (from the flutter-configured build dir):
//   cmake --build build/windows/x64 --target glimpr_tests --config Debug
//   build/windows/x64/test/Debug/glimpr_tests.exe

#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "base64.h"
#include "capture_key_rule.h"
#include "clipboard_dib.h"
#include "clipboard_hdrop.h"
#include "drop_filter.h"
#include "editor_exit_gate.h"
#include "editor_host_state.h"
#include "editor_placement.h"
#include "ed25519/ed25519.h"
#include "hdr_util.h"
#include "install_scope.h"
#include "overlay_ipc.h"
#include "pixel_swizzle.h"
#include "prefs_probe.h"
#include "process_identity.h"
#include "record_args.h"
#include "record_clock.h"
#include "snap_filter.h"
#include "wav_parse.h"

namespace {

int g_checks = 0;
int g_failures = 0;
const char* g_case = "";

void Check(bool cond, const char* expr, const char* file, int line) {
  ++g_checks;
  if (!cond) {
    ++g_failures;
    std::printf("FAIL [%s] %s:%d: %s\n", g_case, file, line, expr);
  }
}

bool Near(double a, double b, double eps) { return std::fabs(a - b) <= eps; }

#define CHECK(cond) Check((cond), #cond, __FILE__, __LINE__)

// --- base64 -----------------------------------------------------------------

void TestBase64RoundTrip() {
  g_case = "base64";
  const char* cases[] = {
      "",
      "a",
      "ab",
      "abc",
      "abcd",
      "C:/Users/name with spaces/Pictures/Glimpr/shot 001.png",
  };
  for (const char* c : cases) {
    std::string in(c);
    CHECK(b64::Decode(b64::Encode(in)) == in);
  }
  // Non-ASCII (UTF-8) bytes survive the round-trip too.
  std::string utf8;
  utf8.push_back((char)0xE6);
  utf8.push_back((char)0x88);
  utf8.push_back((char)0x91);  // U+6211
  CHECK(b64::Decode(b64::Encode(utf8)) == utf8);
  // Known vector.
  CHECK(b64::Encode("foobar") == "Zm9vYmFy");
  CHECK(b64::Decode("Zm9vYmFy") == "foobar");
}

// --- pixel swizzle ----------------------------------------------------------

void TestRgbaToBgra() {
  g_case = "rgba->bgra";
  std::vector<uint8_t> rgba = {10, 20, 30, 40, 50, 60, 70, 80};
  std::vector<uint8_t> bgra = pixfmt::RgbaToBgra(rgba);
  // R<->B swapped, G + A unchanged.
  CHECK(bgra[0] == 30 && bgra[1] == 20 && bgra[2] == 10 && bgra[3] == 40);
  CHECK(bgra[4] == 70 && bgra[5] == 60 && bgra[6] == 50 && bgra[7] == 80);
  // A trailing partial pixel (< 4 bytes) is left untouched, no overrun.
  std::vector<uint8_t> tail = {1, 2, 3, 4, 9, 9};
  std::vector<uint8_t> out = pixfmt::RgbaToBgra(tail);
  CHECK(out[0] == 3 && out[2] == 1 && out[4] == 9 && out[5] == 9);
  CHECK(pixfmt::RgbaToBgra({}).empty());
}

// --- WAV parse --------------------------------------------------------------

void PutU32(std::vector<uint8_t>& v, uint32_t n) {
  v.push_back(n & 0xFF);
  v.push_back((n >> 8) & 0xFF);
  v.push_back((n >> 16) & 0xFF);
  v.push_back((n >> 24) & 0xFF);
}
void PutU16(std::vector<uint8_t>& v, uint16_t n) {
  v.push_back(n & 0xFF);
  v.push_back((n >> 8) & 0xFF);
}
void PutStr(std::vector<uint8_t>& v, const char* s) {
  for (int i = 0; i < 4; ++i) v.push_back((uint8_t)s[i]);
}

std::vector<uint8_t> MakeWav(const std::vector<uint8_t>& pcm) {
  std::vector<uint8_t> w;
  PutStr(w, "RIFF");
  PutU32(w, 0);  // riff size (parser ignores it)
  PutStr(w, "WAVE");
  PutStr(w, "fmt ");
  PutU32(w, 16);            // PCM fmt chunk size
  PutU16(w, 1);            // wFormatTag = PCM
  PutU16(w, 2);            // channels
  PutU32(w, 48000);        // samples/sec
  PutU32(w, 48000 * 4);    // avg bytes/sec
  PutU16(w, 4);            // block align
  PutU16(w, 16);           // bits/sample
  PutStr(w, "data");
  PutU32(w, (uint32_t)pcm.size());
  for (uint8_t b : pcm) w.push_back(b);
  return w;
}

void TestParseWav() {
  g_case = "wav";
  std::vector<uint8_t> pcm = {1, 2, 3, 4, 5, 6, 7, 8};
  std::vector<uint8_t> wav = MakeWav(pcm);
  WAVEFORMATEX fmt = {};
  const uint8_t* out_pcm = nullptr;
  uint32_t out_len = 0;
  CHECK(wavfmt::ParseWav(wav.data(), wav.size(), fmt, out_pcm, out_len));
  CHECK(fmt.wFormatTag == 1 && fmt.nChannels == 2);
  CHECK(fmt.nSamplesPerSec == 48000 && fmt.wBitsPerSample == 16);
  CHECK(fmt.cbSize == 0);
  CHECK(out_len == pcm.size());
  CHECK(out_pcm != nullptr && out_pcm[0] == 1 && out_pcm[7] == 8);

  // Garbage / truncation reject.
  std::vector<uint8_t> junk = {'N', 'O', 'P', 'E', 0, 0, 0, 0};
  CHECK(!wavfmt::ParseWav(junk.data(), junk.size(), fmt, out_pcm, out_len));
  CHECK(!wavfmt::ParseWav(wav.data(), 8, fmt, out_pcm, out_len));  // < 12
  // A header claiming more data than present: the data chunk overruns -> reject.
  std::vector<uint8_t> lying = MakeWav(pcm);
  lying[lying.size() - pcm.size() - 1] = 0xFF;  // corrupt high byte of data len
  CHECK(!wavfmt::ParseWav(lying.data(), lying.size(), fmt, out_pcm, out_len));
}

// --- record worker arg parsing ---------------------------------------------

std::vector<std::wstring> Args(std::initializer_list<const wchar_t*> a) {
  std::vector<std::wstring> v;
  for (const wchar_t* s : a) v.push_back(s);
  return v;
}

void TestParseSpecDefaults() {
  g_case = "parsespec-defaults";
  Recorder::Spec s = recordargs::ParseSpec(Args({L"--record-worker"}));
  CHECK(s.mode == Recorder::Mode::kDisplay);
  CHECK(s.fps == 30);         // 0 -> floor 30
  CHECK(s.gif_fps == 15);     // 0 -> floor 15
  CHECK(s.video_quality == "high");
  CHECK(s.show_cursor == true);  // absent --cursor -> not "0" -> true
  CHECK(s.hevc == false && s.gif == false && s.system_audio == false);
}

void TestParseSpecFull() {
  g_case = "parsespec-full";
  // Round-trip the recorder client's contract: base64 output path, all flags.
  const std::string path = "D:/Rec/my clip.mp4";
  const std::string enc = b64::Encode(path);
  const std::wstring outb64 =
      L"--output-b64=" + std::wstring(enc.begin(), enc.end());
  std::vector<std::wstring> args = {
      L"--record-worker", L"--mode=region",   outb64,
      L"--display=7",     L"--window=42",     L"--x=1.5",
      L"--y=2.5",         L"--w=300",         L"--h=200",
      L"--fps=60",        L"--hevc=1",        L"--hdr=1",
      L"--gif=0",         L"--giffps=25",     L"--cursor=0",
      L"--quality=medium",L"--maxlong=1920",  L"--maxdur=90",
      L"--sysaudio=1",    L"--mic=1",         L"--merge=1"};
  Recorder::Spec s = recordargs::ParseSpec(args);
  CHECK(s.mode == Recorder::Mode::kRegion);
  CHECK(s.output_path == path);  // base64 decoded
  CHECK(s.display_id == 7 && s.window_id == 42);
  CHECK(Near(s.x, 1.5, 1e-9) && Near(s.y, 2.5, 1e-9));
  CHECK(Near(s.w, 300, 1e-9) && Near(s.h, 200, 1e-9));
  CHECK(s.fps == 60 && s.gif_fps == 25);
  CHECK(s.hevc == true && s.hdr == true && s.gif == false);
  CHECK(s.show_cursor == false);  // explicit "0"
  CHECK(s.video_quality == "medium");
  CHECK(s.max_long_side == 1920 && s.max_duration_sec == 90);
  CHECK(s.system_audio == true && s.microphone == true && s.merge_audio == true);

  CHECK(recordargs::ParseSpec(Args({L"--mode=window"})).mode ==
        Recorder::Mode::kWindow);
}

// --- HDR tone-map math ------------------------------------------------------

void TestHalfFloatRoundTrip() {
  g_case = "half-float";
  const float vals[] = {0.0f, 0.5f, 1.0f, 2.0f, 0.25f, 8.0f};
  for (float v : vals) {
    uint16_t h = hdr::FloatToHalfScalar(v);
    float back = hdr::HalfToFloatScalar(h);
    CHECK(Near(back, v, 1e-2));
  }
}

void TestExtSrgb() {
  g_case = "ext-srgb";
  CHECK(Near(hdr::ExtSrgbEncode(0.0f), 0.0f, 1e-4));
  CHECK(Near(hdr::ExtSrgbEncode(1.0f), 1.0f, 1e-3));
  // Encode/decode are inverses within SDR range.
  const float vals[] = {0.1f, 0.35f, 0.75f, 1.0f};
  for (float v : vals) {
    CHECK(Near(hdr::ExtSrgbDecode(hdr::ExtSrgbEncode(v)), v, 1e-3));
  }
  // Monotonic across SDR white.
  CHECK(hdr::ExtSrgbEncode(0.2f) < hdr::ExtSrgbEncode(0.8f));
}

void TestToneMapLut() {
  g_case = "tonemap-lut";
  hdr::ToneMapLut lut;
  CHECK(!lut.built());
  lut.Build(240.0f);
  CHECK(lut.built());

  // One RGBA16F pixel: R = SDR white (1.0 relative), G mid, B = 0.
  // scRGB 1.0 == 80 nits, SDR white 240 nits -> divide by 3 lands SDR white
  // exactly at [0,1]; so a value of 3.0 maps to full white.
  auto half = [](float f) { return hdr::FloatToHalfScalar(f); };
  uint16_t px[4] = {half(3.0f), half(1.5f), half(0.0f), half(1.0f)};

  uint8_t bgra[4] = {0, 0, 0, 0};
  lut.MapToBgra(px, 1, bgra);
  // Alpha forced opaque; BGRA order (blue lane from input B=0, red lane from R).
  CHECK(bgra[3] == 255);
  CHECK(bgra[0] < bgra[2]);           // blue(0) darker than red(white)
  CHECK(bgra[2] >= 250);              // R at/above SDR white -> ~255

  uint8_t rgba[4] = {0, 0, 0, 0};
  lut.MapToRgba(px, 1, rgba);
  CHECK(rgba[3] == 255);
  CHECK(rgba[0] >= 250);              // red lane first in RGBA
  CHECK(rgba[2] < rgba[0]);           // blue darker
  // Same luminance, different byte order: R lane of RGBA == R lane of BGRA.
  CHECK(rgba[0] == bgra[2] && rgba[2] == bgra[0] && rgba[1] == bgra[1]);
}

// --- QPC 100ns overflow-split ----------------------------------------------

void TestQpc100nsFrom() {
  g_case = "qpc-100ns";
  // At 10 MHz the counter IS already 100ns units.
  CHECK(Qpc100nsFrom(10000000, 10000000) == 10000000);
  // 1 second at a 3.32 MHz timer = 1e7 100ns units, exactly.
  CHECK(Qpc100nsFrom(3320000, 3320000) == 10000000);
  // Half a second.
  CHECK(Qpc100nsFrom(1660000, 3320000) == 5000000);
  // A day's worth of ticks at 10 MHz must not overflow int64 (the split's job):
  // counter * 1e7 would exceed int64 max, but the result stays exact.
  const int64_t day = 86400LL * 10000000LL;  // 100ns units in a day
  CHECK(Qpc100nsFrom(day, 10000000) == day * 1LL);
  // Remainder is carried: (freq + half) ticks -> 1.5s.
  CHECK(Qpc100nsFrom(4980000, 3320000) == 15000000);
  // Degenerate freq falls back to 10 MHz (counter passes through).
  CHECK(Qpc100nsFrom(1234567, 0) == 1234567);
}

// --- snappable-window filter -----------------------------------------------

snapfilter::Candidate GoodWindow() {
  snapfilter::Candidate c;
  c.visible = true;
  c.class_name = L"SomeAppClass";
  c.width = 800;
  c.height = 600;
  return c;
}

void TestSnapFilter() {
  g_case = "snap-filter";
  CHECK(snapfilter::Passes(GoodWindow()));

  auto invisible = GoodWindow();
  invisible.visible = false;
  CHECK(!snapfilter::Passes(invisible));

  auto iconic = GoodWindow();
  iconic.iconic = true;
  CHECK(!snapfilter::Passes(iconic));

  auto cloaked = GoodWindow();
  cloaked.cloaked = true;
  CHECK(!snapfilter::Passes(cloaked));

  auto own = GoodWindow();
  own.is_own_overlay = true;
  CHECK(!snapfilter::Passes(own));

  auto tool = GoodWindow();
  tool.tool_window = true;
  CHECK(!snapfilter::Passes(tool));

  // Near-zero layered alpha is rejected; a higher alpha passes; a layered
  // window with NO LWA_ALPHA (per-pixel) is treated as opaque.
  auto faded = GoodWindow();
  faded.layered = true;
  faded.has_layered_alpha = true;
  faded.layered_alpha = 8;
  CHECK(!snapfilter::Passes(faded));
  faded.layered_alpha = 13;
  CHECK(snapfilter::Passes(faded));
  auto perPixel = GoodWindow();
  perPixel.layered = true;
  perPixel.has_layered_alpha = false;
  CHECK(snapfilter::Passes(perPixel));

  auto nvidia = GoodWindow();
  nvidia.class_name = L"CEF-OSC-WIDGET";
  CHECK(!snapfilter::Passes(nvidia));

  auto tiny = GoodWindow();
  tiny.width = 39;
  CHECK(!snapfilter::Passes(tiny));
  tiny.width = 40;
  tiny.height = 39;
  CHECK(!snapfilter::Passes(tiny));
}

// --- clipboard opaque DIB ----------------------------------------------------

void TestOpaqueDib() {
  g_case = "clipdib";
  // 3x2 BGRA with a padded stride (16 bytes/row), every alpha 255.
  const uint32_t w = 3, h = 2, stride = 16;
  std::vector<uint8_t> src(static_cast<size_t>(stride) * h, 0xCD);
  auto px = [&src, stride](uint32_t x, uint32_t y, uint8_t b, uint8_t g,
                           uint8_t r, uint8_t a) {
    uint8_t* p = src.data() + y * stride + x * 4;
    p[0] = b; p[1] = g; p[2] = r; p[3] = a;
  };
  px(0, 0, 1, 2, 3, 255);
  px(1, 0, 4, 5, 6, 255);
  px(2, 0, 7, 8, 9, 255);
  px(0, 1, 11, 12, 13, 255);
  px(1, 1, 14, 15, 16, 255);
  px(2, 1, 17, 18, 19, 255);
  CHECK(clipdib::AllOpaque(src.data(), w, h, stride));

  std::vector<uint8_t> dib(clipdib::OpaqueDibSize(w, h));
  CHECK(dib.size() == 52 + w * 4 * h);
  clipdib::WriteOpaqueDib(dib.data(), src.data(), w, h, stride);
  auto u32 = [&dib](size_t off) {
    uint32_t v;
    std::memcpy(&v, dib.data() + off, 4);
    return v;
  };
  auto u16 = [&dib](size_t off) {
    uint16_t v;
    std::memcpy(&v, dib.data() + off, 2);
    return v;
  };
  CHECK(u32(0) == 40);  // BITMAPINFOHEADER, not V5
  CHECK(u32(4) == w);
  CHECK(u32(8) == h);  // POSITIVE height: bottom-up
  CHECK(u16(12) == 1 && u16(14) == 32);
  CHECK(u32(16) == 3);  // BI_BITFIELDS
  CHECK(u32(20) == w * 4 * h);
  CHECK(u32(40) == 0x00FF0000u);  // R/G/B masks, NO alpha mask anywhere
  CHECK(u32(44) == 0x0000FF00u);
  CHECK(u32(48) == 0x000000FFu);
  // Bottom-up: the DIB's first pixel row is the image's LAST row; source row
  // padding beyond w*4 is not copied.
  const uint8_t* pix = dib.data() + 52;
  CHECK(pix[0] == 11 && pix[1] == 12 && pix[2] == 13 && pix[3] == 255);
  CHECK(pix[8] == 17 && pix[11] == 255);   // (2,1) ends the first DIB row
  CHECK(pix[12] == 1 && pix[15] == 255);   // image row 0 comes second

  // A single not-fully-opaque pixel flips the detection.
  px(1, 1, 14, 15, 16, 254);
  CHECK(!clipdib::AllOpaque(src.data(), w, h, stride));
}

// --- clipboard CF_HDROP payload ----------------------------------------------

void TestDropFilesPayload() {
  g_case = "hdrop";
  const std::wstring path = L"D:\\Videos\\rec 01.gif";
  const std::vector<uint8_t> p = clip::BuildDropFilesPayload(path);
  CHECK(p.size() == sizeof(DROPFILES) + (path.size() + 2) * sizeof(wchar_t));
  DROPFILES drop;
  std::memcpy(&drop, p.data(), sizeof(DROPFILES));
  CHECK(drop.pFiles == sizeof(DROPFILES));
  CHECK(drop.fWide == TRUE);
  const auto* chars =
      reinterpret_cast<const wchar_t*>(p.data() + sizeof(DROPFILES));
  CHECK(std::wstring(chars) == path);
  // The file list is double-null-terminated (one path, then the list's end).
  CHECK(chars[path.size()] == L'\0');
  CHECK(chars[path.size() + 1] == L'\0');
}

// --- editor drop filter -------------------------------------------------------

void TestDropFilter() {
  g_case = "drop-filter";
  CHECK(dropfilter::IsEditorImagePath(L"C:\\Users\\a\\Pictures\\shot.png"));
  CHECK(dropfilter::IsEditorImagePath(L"C:\\a\\PHOTO.JPG"));   // case-blind
  CHECK(dropfilter::IsEditorImagePath(L"D:\\x\\anim.Gif"));
  CHECK(dropfilter::IsEditorImagePath(L"D:\\x\\pic.jpeg"));
  CHECK(dropfilter::IsEditorImagePath(L"D:\\x\\pic.webp"));
  CHECK(dropfilter::IsEditorImagePath(L"D:\\x\\pic.bmp"));
  CHECK(dropfilter::IsEditorImagePath(L"D:\\x\\pic.tiff"));
  CHECK(dropfilter::IsEditorImagePath(L"D:\\dir.png\\also.png"));
  CHECK(!dropfilter::IsEditorImagePath(L"C:\\a\\notes.txt"));
  CHECK(!dropfilter::IsEditorImagePath(L"C:\\a\\archive.zip"));
  CHECK(!dropfilter::IsEditorImagePath(L"C:\\a\\noextension"));
  CHECK(!dropfilter::IsEditorImagePath(L"C:\\dir.png\\file"));  // dot in dir only
  CHECK(!dropfilter::IsEditorImagePath(L"C:\\a\\clip.mp4"));
  CHECK(!dropfilter::IsEditorImagePath(L""));
}

// --- hotkey capture commit rule --------------------------------------------

void TestCaptureKeyRule() {
  g_case = "capture-key";
  // A normal key commits on down (not up), and not on auto-repeat.
  CHECK(ShouldCommitCaptureKey('A', /*down*/ true, /*up*/ false, false));
  CHECK(!ShouldCommitCaptureKey('A', false, true, false));
  CHECK(!ShouldCommitCaptureKey('A', true, false, /*repeat*/ true));
  // PrintScreen commits on UP only (it never delivers a key-down).
  CHECK(ShouldCommitCaptureKey(VK_SNAPSHOT, false, true, false));
  CHECK(!ShouldCommitCaptureKey(VK_SNAPSHOT, true, false, false));
}

// --- ed25519 verify (self-update signature check) ---------------------------

std::vector<unsigned char> HexBytes(const char* hex) {
  std::vector<unsigned char> out;
  for (size_t i = 0; hex[i] && hex[i + 1]; i += 2) {
    auto nib = [](char c) -> unsigned {
      if (c >= '0' && c <= '9') return c - '0';
      return (c | 0x20) - 'a' + 10;
    };
    out.push_back(static_cast<unsigned char>((nib(hex[i]) << 4) |
                                             nib(hex[i + 1])));
  }
  return out;
}

void TestEd25519Verify() {
  g_case = "ed25519";
  // RFC 8032 TEST 1: empty message.
  auto pk1 = HexBytes(
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
  auto sig1 = HexBytes(
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb882"
      "1590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b");
  const unsigned char empty[1] = {0};
  CHECK(ed25519_verify(sig1.data(), empty, 0, pk1.data()) == 1);
  // RFC 8032 TEST 2: one-byte message 0x72.
  auto pk2 = HexBytes(
      "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c");
  auto sig2 = HexBytes(
      "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1"
      "e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00");
  const unsigned char msg2[] = {0x72};
  CHECK(ed25519_verify(sig2.data(), msg2, 1, pk2.data()) == 1);
  // A single flipped bit in the signature must fail.
  sig2[0] ^= 0x01;
  CHECK(ed25519_verify(sig2.data(), msg2, 1, pk2.data()) == 0);
  // The wrong public key must fail.
  CHECK(ed25519_verify(sig1.data(), msg2, 1, pk1.data()) == 0);
}

void TestOverlayIpc() {
  // CALL round-trip with binary + UTF-8 + newline bytes in the payload.
  std::string payload("a\0b\n", 4);
  payload += "\xe4\xb8\xad\xe6\x96\x87";
  const std::string line = oipc::Format("CALL", "pinImage", payload);
  CHECK(line.find('\n') == std::string::npos);
  CHECK(line.rfind("CALL pinImage ", 0) == 0);
  oipc::Message m = oipc::Parse(line + "\r\n");  // pipe CRLF tolerance
  CHECK(m.ok && m.verb == "CALL" && m.method == "pinImage");
  CHECK(m.payload == payload);

  // Bare verbs and payload-less calls.
  CHECK(oipc::Format("READY") == "READY");
  m = oipc::Parse("READY");
  CHECK(m.ok && m.verb == "READY" && m.method.empty());
  m = oipc::Parse("BYE");
  CHECK(m.ok && m.verb == "BYE");
  m = oipc::Parse("CALL openSettings");
  CHECK(m.ok && m.method == "openSettings" && m.payload.empty());

  // Malformed lines never parse as ok.
  CHECK(!oipc::Parse("").ok);
  CHECK(!oipc::Parse("CALL").ok);
  CHECK(!oipc::Parse("PERF").ok);
  CHECK(!oipc::Parse("CALL pin-Image AAAA").ok);
  CHECK(!oipc::Parse("CALL pinImage not*base64").ok);
  CHECK(!oipc::Parse("CALL pinImage AAA").ok);  // length not a multiple of 4
  CHECK(!oipc::Parse("12 34").ok);

  // BEGIN flags, all four combinations.
  for (int p = 0; p < 2; ++p) {
    for (int l = 0; l < 2; ++l) {
      bool pin = !p, live = !l;
      const oipc::Message b = oipc::Parse(oipc::FormatBegin(p != 0, l != 0));
      CHECK(oipc::ParseBegin(b, &pin, &live));
      CHECK(pin == (p != 0) && live == (l != 0));
    }
  }
  bool pin = false, live = false;
  CHECK(!oipc::ParseBegin(oipc::Parse("BEGIN"), &pin, &live));
  CHECK(!oipc::ParseBegin(oipc::Parse("BEGIN 1"), &pin, &live));
  CHECK(!oipc::ParseBegin(oipc::Parse("BEGIN 2 0"), &pin, &live));
  CHECK(!oipc::ParseBegin(oipc::Parse("READY"), &pin, &live));
}

void TestPrefsProbe() {
  // Compact shared_preferences JSON; a longer key ending in the probed key
  // must never match, and a value equal to the key must be skipped.
  const std::string j =
      "{\"a\":1,\"x_gpu_preference\":\"high_performance\","
      "\"b\":\"gpu_preference\",\"gpu_preference\":\"low_power\","
      "\"c\":true}";
  CHECK(prefs::JsonStringValue(j, "gpu_preference") == "low_power");
  CHECK(prefs::JsonStringValue(j, "missing").empty());
  CHECK(prefs::JsonStringValue("{\"gpu_preference\":true}",
                               "gpu_preference").empty());
  CHECK(prefs::JsonStringValue("{\"gpu_preference\": \"system\"}",
                               "gpu_preference") == "system");
  CHECK(prefs::JsonStringValue("{\"gpu_preference\":\"unterminated",
                               "gpu_preference").empty());
  CHECK(prefs::JsonStringValue("", "gpu_preference").empty());
  CHECK(prefs::GpuChoiceFromWire("low_power") == prefs::GpuChoice::kLowPower);
  CHECK(prefs::GpuChoiceFromWire("high_performance") ==
        prefs::GpuChoice::kHighPerformance);
  CHECK(prefs::GpuChoiceFromWire("system") == prefs::GpuChoice::kSystem);
  CHECK(prefs::GpuChoiceFromWire("integrated") == prefs::GpuChoice::kSystem);
  CHECK(prefs::GpuChoiceFromWire("") == prefs::GpuChoice::kSystem);
  // The identity-aware prefs dir ends with the build's own app name.
  const std::wstring dir = prefs::PrefsDir();
  const std::wstring tail = std::wstring(L"\\Howar31\\") + GLIMPR_APP_NAME_W;
  CHECK(dir.size() > tail.size() &&
        dir.compare(dir.size() - tail.size(), tail.size(), tail) == 0);
}

// --- editor host ------------------------------------------------------------

void TestEditorPlacement() {
  eplace::Placement p{-100, 40, 1500, 900, 3};  // SW_SHOWMAXIMIZED
  const std::string s = eplace::Encode(p);
  CHECK(s == "-100,40,1500,900,3");
  eplace::Placement q{};
  CHECK(eplace::Parse(s, &q));
  CHECK(q.left == -100 && q.top == 40 && q.right == 1500 && q.bottom == 900);
  CHECK(q.show_cmd == 3);
  CHECK(!eplace::Parse("", &q));
  CHECK(!eplace::Parse("1,2,3", &q));
  CHECK(!eplace::Parse("a,b,c,d,e", &q));
  CHECK(!eplace::Parse("1,2,3,4,5,6", &q));
  CHECK(!eplace::Parse("1,2,3,4,", &q));
  // A degenerate rect never parses (right <= left or bottom <= top).
  CHECK(!eplace::Parse("10,10,10,50,1", &q));
  // Unknown show commands normalise to SW_SHOWNORMAL (1).
  CHECK(eplace::Parse("0,0,800,600,99", &q) && q.show_cmd == 1);
}

void TestEditorExitGate() {
  egate::State st;
  egate::Inputs in{true, false, true, 1000};
  CHECK(!egate::MayExit(in, &st));  // arms, starts settling
  in.now_ms = 1500;
  CHECK(!egate::MayExit(in, &st));
  in.now_ms = 2000;
  CHECK(egate::MayExit(in, &st));  // 1 s settled
  // Processing blocks and resets the settle clock.
  st = egate::State{};
  in = egate::Inputs{true, true, true, 1000};
  CHECK(!egate::MayExit(in, &st));
  in.now_ms = 5000;
  CHECK(!egate::MayExit(in, &st));
  in.processing = false;
  in.now_ms = 5100;
  CHECK(!egate::MayExit(in, &st));
  in.now_ms = 6100;
  CHECK(egate::MayExit(in, &st));
  // Sound still playing blocks the same way.
  st = egate::State{};
  in = egate::Inputs{true, false, false, 1000};
  CHECK(!egate::MayExit(in, &st));
  in.now_ms = 3000;
  CHECK(!egate::MayExit(in, &st));
  // Hard bound: a stuck export still lets the process go after 10 s.
  in.now_ms = 11000;
  CHECK(egate::MayExit(in, &st));
  // A reveal disarms.
  st = egate::State{};
  in = egate::Inputs{true, false, true, 1000};
  CHECK(!egate::MayExit(in, &st));
  in.hidden = false;
  in.now_ms = 1500;
  CHECK(!egate::MayExit(in, &st));
  CHECK(st.armed_ms == 0);
  in.hidden = true;
  in.now_ms = 2000;
  CHECK(!egate::MayExit(in, &st));
  in.now_ms = 2900;
  CHECK(!egate::MayExit(in, &st));
  in.now_ms = 3000;
  CHECK(egate::MayExit(in, &st));
}

void TestEditorHostState() {
  using namespace ehstate;
  using A = Machine::Action;
  Machine m;
  // Request while none: spawn, keep it pending, deliver on READY.
  CHECK(m.OnRequest(Pending::kPath, "C:\\a.png") == A::kSpawn);
  CHECK(m.OnSpawned(true) == A::kNone && m.state == State::kSpawning);
  // A plain reveal must not downgrade the pending path.
  CHECK(m.OnRequest(Pending::kReveal, "") == A::kNone);
  CHECK(m.pending.kind == Pending::kPath && m.pending.path == "C:\\a.png");
  // A newer path replaces it.
  CHECK(m.OnRequest(Pending::kPath, "C:\\b.png") == A::kNone);
  CHECK(m.pending.path == "C:\\b.png");
  CHECK(m.OnReady() == A::kSendPending && m.state == State::kOpen);
  m.pending = Pending{};  // the client consumes it
  // Open: requests go straight through.
  CHECK(m.OnRequest(Pending::kClipboard, "") == A::kSend);
  CHECK(m.pending.kind == Pending::kNoneKind);
  // Normal end.
  CHECK(m.OnBye() == A::kNone && m.state == State::kEnding && m.said_bye);
  CHECK(m.OnExit() == A::kNone && m.state == State::kNone);
  // A request during kEnding waits for the exit, then respawns.
  m.said_bye = false;
  m.OnRequest(Pending::kReveal, "");
  m.OnSpawned(true);
  m.OnReady();
  m.OnBye();
  CHECK(m.OnRequest(Pending::kReveal, "") == A::kNone);
  CHECK(m.OnExit() == A::kSpawn && m.pending.kind == Pending::kReveal);
  // Crash (EOF without BYE) from kOpen drops to kNone with nothing pending.
  Machine c;
  c.OnRequest(Pending::kReveal, "");
  c.OnSpawned(true);
  c.OnReady();
  c.pending = Pending{};
  CHECK(c.OnExit() == A::kNone && c.state == State::kNone && !c.said_bye);
  // Spawn failure drops the pending request.
  Machine f;
  f.OnRequest(Pending::kPath, "x");
  CHECK(f.OnSpawned(false) == A::kDropPending && f.state == State::kNone);
  CHECK(f.pending.kind == Pending::kNoneKind);
}

void TestProcessIdentity() {
  CHECK(procid::SameExePath(L"C:\\A\\glimpr.exe", L"c:\\a\\GLIMPR.EXE"));
  CHECK(!procid::SameExePath(L"C:\\a\\glimpr.exe", L"C:\\a\\glimpr_dev.exe"));
  CHECK(!procid::SameExePath(L"", L"x"));
  CHECK(procid::IsOurProcess(GetCurrentProcessId()));
  CHECK(!procid::IsOurProcess(0));
  CHECK(!procid::OwnExePath().empty());
}

// --- install scope ------------------------------------------------------------

void TestInstallScope() {
  g_case = "install-scope";
  using install_scope::Effective;
  using install_scope::InstallerParams;
  using install_scope::NeedsElevation;
  using install_scope::Scope;
  using install_scope::Target;
  using install_scope::TargetFromString;

  // keep = the current scope; a named target wins over the current one.
  CHECK(Effective(Scope::kUser, Target::kKeep) == Scope::kUser);
  CHECK(Effective(Scope::kMachine, Target::kKeep) == Scope::kMachine);
  CHECK(Effective(Scope::kUser, Target::kMachine) == Scope::kMachine);
  CHECK(Effective(Scope::kMachine, Target::kUser) == Scope::kUser);

  // Only a per-user update runs un-elevated.
  CHECK(!NeedsElevation(Scope::kUser, Scope::kUser));
  CHECK(NeedsElevation(Scope::kMachine, Scope::kMachine));
  CHECK(NeedsElevation(Scope::kUser, Scope::kMachine));
  CHECK(NeedsElevation(Scope::kMachine, Scope::kUser));

  // Flags never mix and the PID handshake is always present.
  CHECK(InstallerParams(Scope::kUser, 4242) ==
        L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /PID=4242 /CURRENTUSER");
  CHECK(InstallerParams(Scope::kMachine, 7) ==
        L"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /PID=7 /ALLUSERS");

  CHECK(TargetFromString("machine") == Target::kMachine);
  CHECK(TargetFromString("user") == Target::kUser);
  CHECK(TargetFromString("keep") == Target::kKeep);
  CHECK(TargetFromString("") == Target::kKeep);
  CHECK(std::string(install_scope::ScopeName(Scope::kMachine)) == "machine");
  CHECK(std::string(install_scope::ScopeName(Scope::kUser)) == "user");
  CHECK(std::string(install_scope::ScopeName(Scope::kNone)).empty());
}

}  // namespace

int main() {
  // Unbuffered so every line (incl. a FAIL) survives even if a later test
  // faults; block buffering to a pipe otherwise loses it all.
  setvbuf(stdout, nullptr, _IONBF, 0);
  struct Case {
    const char* name;
    void (*fn)();
  };
  const Case cases[] = {
      {"base64", TestBase64RoundTrip},   {"rgba", TestRgbaToBgra},
      {"wav", TestParseWav},             {"parsespec-def", TestParseSpecDefaults},
      {"parsespec-full", TestParseSpecFull}, {"half", TestHalfFloatRoundTrip},
      {"ext-srgb", TestExtSrgb},         {"tonemap", TestToneMapLut},
      {"qpc-100ns", TestQpc100nsFrom},   {"snap-filter", TestSnapFilter},
      {"capture-key", TestCaptureKeyRule}, {"clipdib", TestOpaqueDib},
      {"hdrop", TestDropFilesPayload},     {"drop-filter", TestDropFilter},
      {"ed25519", TestEd25519Verify},     {"overlay-ipc", TestOverlayIpc},
      {"prefs-probe", TestPrefsProbe}, {"editor-placement", TestEditorPlacement},
      {"editor-gate", TestEditorExitGate}, {"editor-state", TestEditorHostState},
      {"process-identity", TestProcessIdentity},
      {"install-scope", TestInstallScope},
  };
  for (const Case& c : cases) {
    std::printf("run %s\n", c.name);
    c.fn();
    std::printf("ok %s\n", c.name);
  }
  std::printf("glimpr_tests: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures;
}
