// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"os"
	"path/filepath"
	"strings"
)

// Dep is one pinned build dependency shown on the Dependencies info screen.
type Dep struct {
	Name     string // display name, e.g. "FFmpeg"
	EnvVar   string // version env var in _versions.sh, e.g. "FFMPEG_VERSION" ("" if per-platform)
	Version  string // fallback/default version (used if _versions.sh can't be read)
	License  string // SPDX-ish license id
	Category string // grouping (see below)
	Purpose  string // one-line role in the build (<= ~70 chars)
	URL      string // project homepage
}

// dependencyCatalog returns the static dependency metadata, in display order.
func dependencyCatalog() []Dep {
	return []Dep{
		// Player core
		{
			Name:     "mpv",
			EnvVar:   "MPV_VERSION",
			Version:  "0.41.0",
			License:  "GPL-2.0+",
			Category: "Player core",
			Purpose:  "The player core (libmpv), built with --gpl",
			URL:      "https://mpv.io",
		},
		{
			Name:     "FFmpeg",
			EnvVar:   "FFMPEG_VERSION",
			Version:  "8.1.1",
			License:  "LGPL-2.1+ / GPL-2.0+ (this build is GPL)",
			Category: "Player core",
			Purpose:  "Audio demux/decode/filter engine (libav*)",
			URL:      "https://ffmpeg.org",
		},

		// Subtitles / Fonts
		{
			Name:     "libass",
			EnvVar:   "LIBASS_VERSION",
			Version:  "0.17.4",
			License:  "ISC",
			Category: "Subtitles / Fonts",
			Purpose:  "Subtitle/ASS renderer (dead-stripped in audio-only)",
			URL:      "https://github.com/libass/libass",
		},
		{
			Name:     "FreeType",
			EnvVar:   "FREETYPE_VERSION",
			Version:  "2.14.3",
			License:  "FTL / GPL-2.0",
			Category: "Subtitles / Fonts",
			Purpose:  "Font rasterizer (libass dep)",
			URL:      "https://freetype.org",
		},
		{
			Name:     "FriBidi",
			EnvVar:   "FRIBIDI_VERSION",
			Version:  "1.0.16",
			License:  "LGPL-2.1+",
			Category: "Subtitles / Fonts",
			Purpose:  "Unicode bidirectional text (libass dep)",
			URL:      "https://github.com/fribidi/fribidi",
		},
		{
			Name:     "HarfBuzz",
			EnvVar:   "HARFBUZZ_VERSION",
			Version:  "14.2.0",
			License:  "MIT",
			Category: "Subtitles / Fonts",
			Purpose:  "Text shaping engine (libass dep)",
			URL:      "https://harfbuzz.github.io",
		},
		{
			Name:     "fontconfig",
			EnvVar:   "FONTCONFIG_VERSION",
			Version:  "2.16.0",
			License:  "MIT",
			Category: "Subtitles / Fonts",
			Purpose:  "Font discovery/config (libass dep)",
			URL:      "https://www.freedesktop.org/wiki/Software/fontconfig/",
		},
		{
			Name:     "expat",
			EnvVar:   "LIBEXPAT_VERSION",
			Version:  "2.8.1",
			License:  "MIT",
			Category: "Subtitles / Fonts",
			Purpose:  "XML parser (fontconfig dep)",
			URL:      "https://libexpat.github.io",
		},

		// Compression
		{
			Name:     "zlib",
			EnvVar:   "ZLIB_VERSION",
			Version:  "1.3.2",
			License:  "Zlib",
			Category: "Compression",
			Purpose:  "DEFLATE compression",
			URL:      "https://zlib.net",
		},
		{
			Name:     "xz/liblzma",
			EnvVar:   "XZ_VERSION",
			Version:  "5.8.3",
			License:  "0BSD / public-domain",
			Category: "Compression",
			Purpose:  "LZMA compression (ffmpeg)",
			URL:      "https://tukaani.org/xz/",
		},
		{
			Name:     "bzip2",
			EnvVar:   "BZIP2_VERSION",
			Version:  "1.0.8",
			License:  "bzip2",
			Category: "Compression",
			Purpose:  "bzip2 compression (freetype optional)",
			URL:      "https://sourceware.org/bzip2/",
		},

		// Text / XML / i18n
		{
			Name:     "libxml2",
			EnvVar:   "LIBXML2_VERSION",
			Version:  "2.14.6",
			License:  "MIT",
			Category: "Text / XML / i18n",
			Purpose:  "XML parser for ffmpeg DASH/IMF demuxers",
			URL:      "https://gitlab.gnome.org/GNOME/libxml2",
		},
		{
			Name:     "libiconv",
			EnvVar:   "LIBICONV_VERSION",
			Version:  "1.18",
			License:  "LGPL-2.1+",
			Category: "Text / XML / i18n",
			Purpose:  "Charset conversion (Android/Windows, no system iconv)",
			URL:      "https://www.gnu.org/software/libiconv/",
		},

		// Imaging
		{
			Name:     "libpng",
			EnvVar:   "LIBPNG_VERSION",
			Version:  "1.6.58",
			License:  "Libpng",
			Category: "Imaging",
			Purpose:  "PNG image codec (cover art / freetype)",
			URL:      "http://www.libpng.org/pub/png/libpng.html",
		},

		// Audio DSP
		{
			Name:     "rubberband",
			EnvVar:   "RUBBERBAND_VERSION",
			Version:  "4.0.0",
			License:  "GPL-2.0+",
			Category: "Audio DSP",
			Purpose:  "Time-stretch/pitch-shift (arubberband + mpv)",
			URL:      "https://breakfastquay.com/rubberband/",
		},
		{
			Name:     "speexdsp",
			EnvVar:   "SPEEXDSP_VERSION",
			Version:  "1.2.1",
			License:  "BSD-3-Clause",
			Category: "Audio DSP",
			Purpose:  "Speex DSP / resampler",
			URL:      "https://www.speex.org",
		},

		// Network / TLS
		{
			Name:     "OpenSSL",
			EnvVar:   "OPENSSL_VERSION",
			Version:  "3.5.6",
			License:  "Apache-2.0",
			Category: "Network / TLS",
			Purpose:  "TLS backend (https) on every platform",
			URL:      "https://www.openssl.org",
		},
		{
			Name:     "libsmb2",
			EnvVar:   "LIBSMB2_VERSION",
			Version:  "6.0.0",
			License:  "LGPL-2.1+",
			Category: "Network / TLS",
			Purpose:  "SMB2/3 client for NAS playback",
			URL:      "https://github.com/sahlberg/libsmb2",
		},

		// Rendering (linked)
		{
			Name:     "libplacebo",
			EnvVar:   "",
			Version:  "per-platform",
			License:  "LGPL-2.1+",
			Category: "Rendering (linked)",
			Purpose:  "GPU shader/render lib (dead-stripped in audio-only)",
			URL:      "https://libplacebo.org",
		},

		// Toolchain
		{
			Name:     "Android NDK",
			EnvVar:   "",
			Version:  "per-platform",
			License:  "Android NDK License",
			Category: "Toolchain",
			Purpose:  "Android cross-compile toolchain (build_libmpv_android.sh)",
			URL:      "https://developer.android.com/ndk",
		},
	}
}

// readPinnedVersions parses `scripts/shared/_versions.sh` under scriptsRoot and
// returns a map of env-var name -> pinned value, by matching lines of the form
//
//	export NAME="${NAME:-VALUE}"
//
// Returns an empty (non-nil) map if the file can't be read, so callers can
// safely fall back to Dep.Version.
func readPinnedVersions(scriptsRoot string) map[string]string {
	out := make(map[string]string)

	path := filepath.Join(scriptsRoot, "scripts", "shared", "_versions.sh")
	data, err := os.ReadFile(path)
	if err != nil {
		return out
	}

	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)

		// Strip an optional leading "export ".
		line = strings.TrimPrefix(line, "export ")

		// Must look like NAME="${NAME:-VALUE}".
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		name := strings.TrimSpace(line[:eq])
		if name == "" {
			continue
		}

		rest := line[eq+1:]
		marker := strings.Index(rest, ":-")
		if marker < 0 {
			continue
		}
		value := rest[marker+2:]

		// Cut at the closing `}` of the parameter expansion.
		if brace := strings.IndexByte(value, '}'); brace >= 0 {
			value = value[:brace]
		}

		// Trim surrounding quotes/space.
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}

		out[name] = value
	}

	return out
}
