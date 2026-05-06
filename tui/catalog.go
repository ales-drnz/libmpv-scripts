// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

// FFKind categorizes a toggleable ffmpeg component.
type FFKind int

const (
	ffDecoder FFKind = iota
	ffFilter
)

// FFItem is one toggleable ffmpeg component (a decoder or an audio filter).
type FFItem struct {
	Name      string // ffmpeg config token, e.g. "aac", "acompressor"
	Title     string // short human label, e.g. "AAC"
	Desc      string // one-line description (<= ~70 chars), factual
	Category  string // grouping label within its Kind (see below)
	Kind      FFKind
	AppleOnly bool // only compiles on macOS/iOS (the *_at decoders)
	Required  bool // cannot be disabled (the config audit asserts it)
	DefaultOn bool // part of the curated default whitelist (built today)
}

// ffmpegCatalog returns the full catalog of user-toggleable ffmpeg components.
func ffmpegCatalog() []FFItem {
	return []FFItem{
		// ---------------------------------------------------------------
		// DECODERS — Lossy
		// ---------------------------------------------------------------
		{Name: "aac", Title: "AAC", Desc: "Advanced Audio Coding — MP4/M4A, YouTube, streaming", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "aac_latm", Title: "AAC LATM", Desc: "AAC in LATM/LOAS framing (broadcast/DVB streams)", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "ac3", Title: "AC-3", Desc: "Dolby Digital surround codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "eac3", Title: "E-AC-3", Desc: "Dolby Digital Plus (enhanced AC-3)", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "dca", Title: "DTS", Desc: "DTS Coherent Acoustics surround codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "opus", Title: "Opus", Desc: "Opus — modern low-latency lossy codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "vorbis", Title: "Vorbis", Desc: "Ogg Vorbis lossy codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp1", Title: "MP1", Desc: "MPEG-1/2 Audio Layer I decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp1float", Title: "MP1 (float)", Desc: "MPEG Audio Layer I, floating-point decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp2", Title: "MP2", Desc: "MPEG-1/2 Audio Layer II decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp2float", Title: "MP2 (float)", Desc: "MPEG Audio Layer II, floating-point decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp3", Title: "MP3", Desc: "MPEG-1/2 Audio Layer III decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp3float", Title: "MP3 (float)", Desc: "MP3, floating-point decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp3adu", Title: "MP3 ADU", Desc: "MP3 ADU (application data unit) framing decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp3adufloat", Title: "MP3 ADU (float)", Desc: "MP3 ADU, floating-point decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp3on4", Title: "MP3on4", Desc: "MP3onMP4 (multichannel MP3 in MP4) decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mp3on4float", Title: "MP3on4 (float)", Desc: "MP3onMP4, floating-point decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "cook", Title: "Cook", Desc: "RealAudio Cook (RealAudio G2) codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "sipr", Title: "SIPR", Desc: "RealAudio SIPR (Sipro ACELP.net) speech codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "ralf", Title: "RALF", Desc: "RealAudio Lossless Format decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "speex", Title: "Speex", Desc: "Speex speech codec (native decoder)", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "nellymoser", Title: "Nellymoser", Desc: "Nellymoser Asao codec (Flash audio)", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "gsm", Title: "GSM", Desc: "GSM 06.10 full-rate speech codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "gsm_ms", Title: "GSM-MS", Desc: "Microsoft variant of GSM 06.10 speech codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "atrac3", Title: "ATRAC3", Desc: "Sony ATRAC3 codec (MiniDisc, PSP)", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "atrac3p", Title: "ATRAC3+", Desc: "Sony ATRAC3plus codec (PSP, UMD)", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "atrac9", Title: "ATRAC9", Desc: "Sony ATRAC9 codec (PS Vita, PS4)", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mpc7", Title: "Musepack SV7", Desc: "Musepack stream version 7 decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "mpc8", Title: "Musepack SV8", Desc: "Musepack stream version 8 decoder", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "wmav1", Title: "WMA v1", Desc: "Windows Media Audio 1 codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "wmav2", Title: "WMA v2", Desc: "Windows Media Audio 2 codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "wmapro", Title: "WMA Pro", Desc: "Windows Media Audio 9 Professional codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},
		{Name: "wmavoice", Title: "WMA Voice", Desc: "Windows Media Audio Voice speech codec", Category: "Lossy", Kind: ffDecoder, DefaultOn: true},

		// ---------------------------------------------------------------
		// DECODERS — Lossless
		// ---------------------------------------------------------------
		{Name: "alac", Title: "ALAC", Desc: "Apple Lossless Audio Codec", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "flac", Title: "FLAC", Desc: "Free Lossless Audio Codec", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "ape", Title: "Monkey's Audio", Desc: "Monkey's Audio (APE) lossless codec", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "tta", Title: "TTA", Desc: "True Audio (TTA) lossless codec", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "wavpack", Title: "WavPack", Desc: "WavPack lossless / hybrid codec", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "wmalossless", Title: "WMA Lossless", Desc: "Windows Media Audio 9 Lossless codec", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "mlp", Title: "MLP", Desc: "Meridian Lossless Packing decoder", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "truehd", Title: "Dolby TrueHD", Desc: "Dolby TrueHD lossless codec (Blu-ray)", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "shorten", Title: "Shorten", Desc: "Shorten (SHN) lossless codec", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},
		{Name: "s302m", Title: "SMPTE 302M", Desc: "SMPTE 302M PCM audio (broadcast MPEG-TS)", Category: "Lossless", Kind: ffDecoder, DefaultOn: true},

		// ---------------------------------------------------------------
		// DECODERS — DSD
		// ---------------------------------------------------------------
		{Name: "dsd_lsbf", Title: "DSD LSB-first", Desc: "Direct Stream Digital, LSB-first (SACD)", Category: "DSD", Kind: ffDecoder, DefaultOn: true},
		{Name: "dsd_lsbf_planar", Title: "DSD LSB-first (planar)", Desc: "Direct Stream Digital, LSB-first planar", Category: "DSD", Kind: ffDecoder, DefaultOn: true},
		{Name: "dsd_msbf", Title: "DSD MSB-first", Desc: "Direct Stream Digital, MSB-first (SACD)", Category: "DSD", Kind: ffDecoder, DefaultOn: true},
		{Name: "dsd_msbf_planar", Title: "DSD MSB-first (planar)", Desc: "Direct Stream Digital, MSB-first planar", Category: "DSD", Kind: ffDecoder, DefaultOn: true},

		// ---------------------------------------------------------------
		// DECODERS — ADPCM
		// ---------------------------------------------------------------
		{Name: "adpcm_ima_qt", Title: "ADPCM IMA QuickTime", Desc: "IMA ADPCM, Apple QuickTime variant", Category: "ADPCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "adpcm_ms", Title: "ADPCM Microsoft", Desc: "Microsoft ADPCM (WAV) decoder", Category: "ADPCM", Kind: ffDecoder, DefaultOn: true},

		// ---------------------------------------------------------------
		// DECODERS — PCM
		// ---------------------------------------------------------------
		{Name: "pcm_alaw", Title: "PCM A-law", Desc: "G.711 A-law companded PCM", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_mulaw", Title: "PCM mu-law", Desc: "G.711 mu-law companded PCM", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_vidc", Title: "PCM VIDC", Desc: "Acorn VIDC mu-law-style companded PCM", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_bluray", Title: "PCM Blu-ray", Desc: "Blu-ray LPCM decoder", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_dvd", Title: "PCM DVD", Desc: "DVD LPCM decoder", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_lxf", Title: "PCM LXF", Desc: "20-bit packed LPCM (Leitch/Harris LXF)", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s24daud", Title: "PCM S24 D-AUD", Desc: "D-Cinema 24-bit signed PCM", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_f16le", Title: "PCM F16LE", Desc: "16-bit floating-point PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_f24le", Title: "PCM F24LE", Desc: "24-bit floating-point PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_f32be", Title: "PCM F32BE", Desc: "32-bit float PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_f32le", Title: "PCM F32LE", Desc: "32-bit float PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_f64be", Title: "PCM F64BE", Desc: "64-bit float PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_f64le", Title: "PCM F64LE", Desc: "64-bit float PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s8", Title: "PCM S8", Desc: "8-bit signed PCM", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s8_planar", Title: "PCM S8 (planar)", Desc: "8-bit signed PCM, planar", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s16be", Title: "PCM S16BE", Desc: "16-bit signed PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s16be_planar", Title: "PCM S16BE (planar)", Desc: "16-bit signed PCM, big-endian planar", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s16le", Title: "PCM S16LE", Desc: "16-bit signed PCM, little-endian (WAV)", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s16le_planar", Title: "PCM S16LE (planar)", Desc: "16-bit signed PCM, little-endian planar", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s24be", Title: "PCM S24BE", Desc: "24-bit signed PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s24le", Title: "PCM S24LE", Desc: "24-bit signed PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s24le_planar", Title: "PCM S24LE (planar)", Desc: "24-bit signed PCM, little-endian planar", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s32be", Title: "PCM S32BE", Desc: "32-bit signed PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s32le", Title: "PCM S32LE", Desc: "32-bit signed PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s32le_planar", Title: "PCM S32LE (planar)", Desc: "32-bit signed PCM, little-endian planar", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s64be", Title: "PCM S64BE", Desc: "64-bit signed PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_s64le", Title: "PCM S64LE", Desc: "64-bit signed PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_u8", Title: "PCM U8", Desc: "8-bit unsigned PCM", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_u16be", Title: "PCM U16BE", Desc: "16-bit unsigned PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_u16le", Title: "PCM U16LE", Desc: "16-bit unsigned PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_u24be", Title: "PCM U24BE", Desc: "24-bit unsigned PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_u24le", Title: "PCM U24LE", Desc: "24-bit unsigned PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_u32be", Title: "PCM U32BE", Desc: "32-bit unsigned PCM, big-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},
		{Name: "pcm_u32le", Title: "PCM U32LE", Desc: "32-bit unsigned PCM, little-endian", Category: "PCM", Kind: ffDecoder, DefaultOn: true},

		// ---------------------------------------------------------------
		// DECODERS — Apple HW (AudioToolbox, macOS/iOS only)
		// ---------------------------------------------------------------
		{Name: "aac_at", Title: "AAC (AudioToolbox)", Desc: "AAC via Apple AudioToolbox hardware/system decoder", Category: "Apple HW", Kind: ffDecoder, AppleOnly: true, DefaultOn: true},
		{Name: "alac_at", Title: "ALAC (AudioToolbox)", Desc: "Apple Lossless via Apple AudioToolbox decoder", Category: "Apple HW", Kind: ffDecoder, AppleOnly: true, DefaultOn: true},
		{Name: "mp3_at", Title: "MP3 (AudioToolbox)", Desc: "MP3 via Apple AudioToolbox system decoder", Category: "Apple HW", Kind: ffDecoder, AppleOnly: true, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — Dynamics
		// ---------------------------------------------------------------
		{Name: "acompressor", Title: "Compressor", Desc: "Dynamic range compressor", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "alimiter", Title: "Limiter", Desc: "Look-ahead brickwall peak limiter", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "agate", Title: "Noise Gate", Desc: "Expander / noise gate", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "adrc", Title: "Dynamic Range Control", Desc: "Spectral dynamic range controller", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "compand", Title: "Compand", Desc: "Compress or expand dynamic range vs. volume", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "mcompand", Title: "Multiband Compand", Desc: "Multiband compress/expand dynamic range", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "dynaudnorm", Title: "Dynamic Normalizer", Desc: "Dynamic audio normalizer (smooth gain)", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "speechnorm", Title: "Speech Normalizer", Desc: "Speech normalizer / leveler", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "deesser", Title: "De-esser", Desc: "Reduce harsh sibilance ('s' sounds)", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "adynamicequalizer", Title: "Dynamic EQ", Desc: "Frequency-dependent dynamic equalizer", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "adynamicsmooth", Title: "Dynamic Smooth", Desc: "Dynamic smoothing of the signal", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "apsyclip", Title: "Psy Clipper", Desc: "Psychoacoustic clipper", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "asoftclip", Title: "Soft Clip", Desc: "Audio soft clipper (saturation)", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "acrusher", Title: "Bit Crusher", Desc: "Bit/sample crusher (lo-fi distortion)", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "crystalizer", Title: "Crystalizer", Desc: "Simple expand of audio dynamics (sharpen)", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},
		{Name: "aexciter", Title: "Exciter", Desc: "Harmonic exciter (adds upper harmonics)", Category: "Dynamics", Kind: ffFilter, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — EQ & Filtering
		// ---------------------------------------------------------------
		{Name: "equalizer", Title: "Parametric EQ", Desc: "Two-pole peaking parametric equalizer band", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "anequalizer", Title: "N-band EQ", Desc: "Arbitrary multi-band parametric equalizer", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "superequalizer", Title: "Super EQ", Desc: "18-band FFT graphic equalizer", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "firequalizer", Title: "FIR EQ", Desc: "FIR-based arbitrary frequency-response EQ", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "bass", Title: "Bass", Desc: "Boost or cut low (bass) frequencies", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "treble", Title: "Treble", Desc: "Boost or cut high (treble) frequencies", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "highpass", Title: "High-pass", Desc: "High-pass filter (cut lows)", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "lowpass", Title: "Low-pass", Desc: "Low-pass filter (cut highs)", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "highshelf", Title: "High Shelf", Desc: "High-shelf filter", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "lowshelf", Title: "Low Shelf", Desc: "Low-shelf filter", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "tiltshelf", Title: "Tilt Shelf", Desc: "Tilt-shelf filter (broadband spectral tilt)", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "bandpass", Title: "Band-pass", Desc: "Two-pole band-pass filter", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "bandreject", Title: "Band-reject", Desc: "Two-pole band-reject (notch) filter", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "allpass", Title: "All-pass", Desc: "Two-pole all-pass filter (phase shaping)", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "biquad", Title: "Biquad", Desc: "Generic biquad IIR filter (raw coefficients)", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "aiir", Title: "Arbitrary IIR", Desc: "Arbitrary IIR/FIR filter from pole/zero coeffs", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "atilt", Title: "Spectral Tilt", Desc: "Apply a spectral tilt to the audio", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "asubboost", Title: "Sub Boost", Desc: "Boost subwoofer (very low) frequencies", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "asubcut", Title: "Sub Cut", Desc: "High-pass / cut below the subwoofer range", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "asupercut", Title: "Super Cut", Desc: "Steep low-pass to cut ultrasonic content", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "asuperpass", Title: "Super Pass", Desc: "High-order Butterworth band-pass filter", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "asuperstop", Title: "Super Stop", Desc: "High-order Butterworth band-stop filter", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},
		{Name: "aemphasis", Title: "Emphasis", Desc: "Apply or restore RIAA/CD pre-emphasis curves", Category: "EQ & Filtering", Kind: ffFilter, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — Spatial / Stereo
		// ---------------------------------------------------------------
		{Name: "stereotools", Title: "Stereo Tools", Desc: "Stereo field manipulation toolkit", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "stereowiden", Title: "Stereo Widen", Desc: "Widen the stereo image (delay-based)", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "extrastereo", Title: "Extra Stereo", Desc: "Linearly increase stereo separation", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "crossfeed", Title: "Crossfeed", Desc: "Headphone crossfeed (blends L/R)", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "haas", Title: "Haas", Desc: "Haas-effect stereo widening", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "headphone", Title: "Headphone HRTF", Desc: "Binaural HRIR/HRTF virtual surround for headphones", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "surround", Title: "Surround", Desc: "Matrix upmix/downmix between channel layouts", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "earwax", Title: "Earwax", Desc: "Headphone-friendly stereo widening", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "pan", Title: "Pan", Desc: "Remap/mix input channels to output channels", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "channelmap", Title: "Channel Map", Desc: "Remap channels to a new channel layout", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "virtualbass", Title: "Virtual Bass", Desc: "Synthesize perceived bass via harmonics", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "dialoguenhance", Title: "Dialogue Enhance", Desc: "Enhance center dialogue in stereo audio", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},
		{Name: "adecorrelate", Title: "Decorrelate", Desc: "Decorrelate channels (widen, de-mono)", Category: "Spatial / Stereo", Kind: ffFilter, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — Time / Pitch
		// ---------------------------------------------------------------
		{Name: "atempo", Title: "Tempo", Desc: "Change tempo (speed) without altering pitch", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "rubberband", Title: "Rubber Band", Desc: "High-quality time-stretch / pitch-shift (librubberband)", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "aresample", Title: "Resample", Desc: "Resample sample rate / repack audio (libswresample)", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "aformat", Title: "Format", Desc: "Force sample format, rate, or channel layout", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "adelay", Title: "Delay", Desc: "Delay one or more channels by a set time", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "apad", Title: "Pad", Desc: "Pad the end of audio with silence", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "compensationdelay", Title: "Compensation Delay", Desc: "Distance/metric-based compensation delay line", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "afade", Title: "Fade", Desc: "Fade audio in or out", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "aphaseshift", Title: "Phase Shift", Desc: "Apply a phase shift to the audio", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},
		{Name: "afreqshift", Title: "Frequency Shift", Desc: "Apply a frequency shift to the audio", Category: "Time / Pitch", Kind: ffFilter, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — Modulation / FX
		// ---------------------------------------------------------------
		{Name: "aecho", Title: "Echo", Desc: "Add echoes (delay + decay)", Category: "Modulation / FX", Kind: ffFilter, DefaultOn: true},
		{Name: "chorus", Title: "Chorus", Desc: "Chorus effect (modulated delays)", Category: "Modulation / FX", Kind: ffFilter, DefaultOn: true},
		{Name: "flanger", Title: "Flanger", Desc: "Flanging effect (swept comb filter)", Category: "Modulation / FX", Kind: ffFilter, DefaultOn: true},
		{Name: "aphaser", Title: "Phaser", Desc: "Phaser effect (swept all-pass stages)", Category: "Modulation / FX", Kind: ffFilter, DefaultOn: true},
		{Name: "apulsator", Title: "Pulsator", Desc: "Amplitude pulsator (auto-pan / tremolo LFO)", Category: "Modulation / FX", Kind: ffFilter, DefaultOn: true},
		{Name: "tremolo", Title: "Tremolo", Desc: "Amplitude (volume) modulation", Category: "Modulation / FX", Kind: ffFilter, DefaultOn: true},
		{Name: "vibrato", Title: "Vibrato", Desc: "Pitch (frequency) modulation", Category: "Modulation / FX", Kind: ffFilter, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — Restoration / Noise
		// ---------------------------------------------------------------
		{Name: "afftdn", Title: "FFT Denoise", Desc: "FFT-based noise reduction", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "afwtdn", Title: "Wavelet Denoise", Desc: "Wavelet-based noise reduction", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "anlmdn", Title: "NLM Denoise", Desc: "Non-local-means noise reduction", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "arnndn", Title: "RNN Denoise", Desc: "Recurrent-neural-network noise reduction", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "adeclick", Title: "Declick", Desc: "Remove clicks/impulse noise from audio", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "adeclip", Title: "Declip", Desc: "Repair clipped (over-driven) audio", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "adenorm", Title: "Denormal Fix", Desc: "Remedy denormals by adding tiny noise", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "aderivative", Title: "Derivative", Desc: "Compute derivative of the audio signal", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "dcshift", Title: "DC Shift", Desc: "Apply/correct a DC offset on the audio", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "hdcd", Title: "HDCD", Desc: "Decode High Definition Compatible Digital", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},
		{Name: "silenceremove", Title: "Silence Remove", Desc: "Remove silence from start/middle/end", Category: "Restoration / Noise", Kind: ffFilter, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — Loudness / Metering
		// ---------------------------------------------------------------
		{Name: "loudnorm", Title: "Loudness Norm", Desc: "EBU R128 loudness normalization", Category: "Loudness / Metering", Kind: ffFilter, DefaultOn: true},
		{Name: "ebur128", Title: "EBU R128 Meter", Desc: "EBU R128 loudness measurement / metering", Category: "Loudness / Metering", Kind: ffFilter, DefaultOn: true},
		{Name: "drmeter", Title: "DR Meter", Desc: "Measure dynamic range of audio", Category: "Loudness / Metering", Kind: ffFilter, DefaultOn: true},

		// ---------------------------------------------------------------
		// FILTERS — Misc / Analysis
		// ---------------------------------------------------------------
		{Name: "aeval", Title: "Eval", Desc: "Synthesize/modify audio via per-sample expressions", Category: "Misc / Analysis", Kind: ffFilter, DefaultOn: true},
		{Name: "afftfilt", Title: "FFT Filter", Desc: "Apply arbitrary expressions in the frequency domain", Category: "Misc / Analysis", Kind: ffFilter, DefaultOn: true},
		{Name: "acontrast", Title: "Contrast", Desc: "Simple audio contrast / loudness enhancement", Category: "Misc / Analysis", Kind: ffFilter, DefaultOn: true},
	}
}
