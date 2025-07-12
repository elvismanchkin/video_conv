# GPU Video Converter v8.0

A modular, maintainable Bash-based video converter with automatic hardware acceleration detection and optimization.

## Quick Start

```bash
# Run the converter
./cvrt.sh [OPTIONS] [DIRECTORY]

# Examples
./cvrt.sh --help                    # Show help
./cvrt.sh --gpu /path/to/videos     # Convert with GPU acceleration
./cvrt.sh --cpu /path/to/videos     # Convert with CPU (highest quality)
```

## Features

- **Hardware Acceleration**: NVIDIA NVENC, Intel QSV, AMD VAAPI, or software fallback
- **Multi-Format Support**: MKV, MP4, AVI, MOV, M4V, WMV, FLV, WebM, TS, MTS, M2TS
- **Multi-Codec Support**: HEVC (H.265), H.264, AV1, VP9 with automatic selection
- **Advanced Processing**: Scaling, deinterlacing, denoising, sharpening filters
- **Subtitle Handling**: Copy, burn, extract, or remove subtitles
- **Metadata Control**: Copy, strip, or minimal metadata handling

## Documentation

- **[User Guide](docs/USER_GUIDE.md)** - Complete usage guide and examples
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

The script is self-contained and can be run directly. For system-wide installation:

```bash
# Option 1: Using /usr/local/bin (requires sudo)
sudo ln -sf /path/to/video_conv/cvrt.sh /usr/local/bin/cvrt

# Option 2: Using user directory
mkdir -p ~/bin
ln -sf /path/to/video_conv/cvrt.sh ~/bin/cvrt
```

## Prerequisites

Required: `ffmpeg`, `ffprobe`, `jq`

Optional for hardware acceleration: `libva-utils`, `nvidia-smi`

See [User Guide](docs/USER_GUIDE.md) for detailed installation instructions. 