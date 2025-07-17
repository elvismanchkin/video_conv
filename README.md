# GPU Video Converter v8.0

A modular, maintainable Bash-based video converter with automatic hardware acceleration detection and optimization. Converts video files to HEVC (H.265) using the best available encoder: NVIDIA NVENC, Intel QSV, AMD VAAPI, or software fallback.

## Quick Start

```bash
# Run the converter
./cvrt.sh [OPTIONS] [DIRECTORY]

# Examples
./cvrt.sh --help                    # Show help
./cvrt.sh --gpu /path/to/videos     # Convert with GPU acceleration
./cvrt.sh --cpu /path/to/videos     # Convert with CPU (highest quality)
./cvrt.sh --format mp4 --codec h264 /path/to/videos  # Convert to MP4 with H.264
```

## Features

- **Robust CLI Parsing**: Order-independent argument parsing with comprehensive validation
- **Hardware Acceleration**: NVIDIA NVENC, Intel QSV, AMD VAAPI, or software fallback
- **Multi-Format Support**: MKV, MP4, AVI, MOV, M4V, WMV, FLV, WebM, TS, MTS, M2TS
- **Multi-Codec Support**: HEVC (H.265), H.264, AV1, VP9 with automatic selection
- **Advanced Processing**: Scaling, deinterlacing, denoising, sharpening filters
- **Subtitle Handling**: Copy, burn, extract, or remove subtitles
- **Metadata Control**: Copy, strip, or minimal metadata handling
- **Smart Audio Processing**: Preserves non-5.1 tracks, converts 5.1 to stereo when needed
- **RAM Disk Optimization**: Automatic use of `/dev/shm` when available
- **Comprehensive Error Handling**: Graceful fallbacks and detailed logging

## Documentation

- **[Complete User Guide](docs/USER_GUIDE.md)** - Comprehensive usage guide with examples
- **[Developer Guide](docs/HACKING.md)** - Contributing and extending the project
- **[Configuration Examples](examples/)** - Sample configuration files

## Project Structure

```
video_conv/
├── cvrt.sh              # Entry point script
├── src/                 # Main source code
│   ├── cvrt.sh         # Main implementation
│   └── lib/            # Library modules
│       ├── utils.sh          # Logging and utility functions
│       ├── hardware.sh       # Hardware detection and capabilities
│       ├── encoders.sh       # Encoder selection and configuration
│       ├── video_analysis.sh # Video file analysis and metadata
│       ├── audio_processing.sh # Audio conversion and encoding
│       └── video_filters.sh  # Video filter chain
├── config/             # Configuration files
│   └── defaults.conf   # Default configuration settings
├── tests/              # Test files
│   ├── test_argument_parsing.sh
│   ├── test_config_sourcing.sh
│   ├── test_filter_compatibility.sh
│   ├── test_filter_integration.sh
│   └── demo_filter_compatibility.sh
├── scripts/            # Utility scripts
│   ├── ci-local.sh     # Local CI checks
│   └── dev-tools.sh    # Development utilities
├── docs/               # Documentation
│   ├── USER_GUIDE.md   # Complete user documentation
│   └── HACKING.md      # Developer guide
└── examples/           # Example configurations
    └── custom.conf.example
```

## Installation

### Prerequisites

Required: `ffmpeg`, `ffprobe`, `jq`

Optional for hardware acceleration: `libva-utils`, `nvidia-smi`

### System-Wide Installation

The script is self-contained and can be run directly. For system-wide installation:

```bash
# Option 1: Using /usr/local/bin (requires sudo)
sudo ln -sf /path/to/video_conv/cvrt.sh /usr/local/bin/cvrt

# Option 2: Using user directory
mkdir -p ~/bin
ln -sf /path/to/video_conv/cvrt.sh ~/bin/cvrt
# Add to ~/.bashrc: export PATH="$HOME/bin:$PATH"

# Option 3: Using Homebrew bin directory (macOS)
ln -sf /path/to/video_conv/cvrt.sh /opt/homebrew/bin/cvrt
```

### Platform-Specific Setup

**Ubuntu/Debian:**
```bash
sudo apt update && sudo apt install ffmpeg vainfo jq
```

**macOS:**
```bash
brew install ffmpeg jq
```

For detailed installation instructions and troubleshooting, see the [Complete User Guide](docs/USER_GUIDE.md).

## Usage Examples

```bash
# Convert all videos in current directory
./cvrt.sh .

# Convert with GPU acceleration
./cvrt.sh --gpu /media/videos

# Convert to MP4 with H.264 codec
./cvrt.sh --format mp4 --codec h264 /path/to/videos

# High quality conversion with CPU
./cvrt.sh --cpu --quality 18 /path/to/videos

# Scale to 1080p and enable filters
./cvrt.sh --scale 1080p --denoise --sharpen /path/to/videos

# List supported formats and codecs
./cvrt.sh --list-formats
./cvrt.sh --list-codecs
```

## Safety Features

- **Non-destructive by default**: Creates `-converted.mkv` files unless `--replace` is used
- **Automatic fallbacks**: GPU encoding failure → software encoding
- **Input validation**: Comprehensive file and dependency checking
- **Clean error handling**: Proper cleanup and informative error messages

## Development

```bash
# Run all code quality checks
./scripts/ci-local.sh

# Development tools
./scripts/dev-tools.sh all

# Run tests
./tests/test_argument_parsing.sh
```

For contributing guidelines, see [HACKING.md](docs/HACKING.md).