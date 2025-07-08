# GPU-Accelerated Video Converter (`cvrt_v7.sh`)

A powerful Bash script for batch-converting `.mkv` video files using FFmpeg with intelligent hardware acceleration detection and optimization.

Automatically detects and utilizes the best available encoder: NVIDIA NVENC, Intel QSV, AMD VAAPI, or software fallback. Designed for efficient re-encoding of video libraries to HEVC (H.265) with smart audio handling and system resource optimization.

## Features

* **Intelligent Hardware Detection**: Automatically detects and scores available encoders (NVENC > QSV > VAAPI > Software)
* **Multi-Platform GPU Support**: 
  - NVIDIA NVENC (RTX/GTX series with AV1 support for RTX 40+)
  - Intel QSV (integrated and Arc discrete GPUs)
  - AMD VAAPI (APUs and discrete GPUs)
* **Manual Encoder Selection**: Force specific encoders with command-line flags
* **RAM Disk Optimization**: Uses `/dev/shm` for temporary files when available
* **Smart Audio Processing**:
  - Preserves existing non-5.1 audio tracks
  - Converts 5.1 surround to high-quality stereo AAC when needed
* **Hardware-Optimized Settings**: Encoder parameters automatically tuned per hardware type
* **10-bit Video Support**: Handles HDR content when hardware supports it
* **Progress Display**: Real-time FFmpeg progress bars
* **Comprehensive Error Handling**: Automatic fallback chains and detailed debug output

## Prerequisites

### Required Tools
```bash
# Core requirements (all distros)
ffmpeg ffprobe jq

# Hardware acceleration libraries
libva-utils  # For VAAPI support
```

### Distribution-Specific Setup

**Ubuntu/Debian:**
```bash
sudo apt update && sudo apt install ffmpeg vainfo jq
# AMD: sudo apt install mesa-va-drivers
# Intel: sudo apt install intel-media-va-driver
# NVIDIA: sudo apt install libnvidia-encode-470
```

**Fedora:**
```bash
sudo dnf install ffmpeg libva-utils jq mesa-va-drivers
# Better AMD: sudo dnf install mesa-va-drivers-freeworld
# Intel: sudo dnf install intel-media-driver
# NVIDIA: sudo dnf install nvidia-driver
```

**openSUSE:**
```bash
sudo zypper install ffmpeg libva-utils jq libva-mesa-driver
# Intel: sudo zypper install intel-media-driver
# NVIDIA: sudo zypper install nvidia-video-G06
```

**Arch Linux:**
```bash
sudo pacman -S ffmpeg libva-utils jq libva-mesa-driver
# Intel: sudo pacman -S intel-media-driver
# NVIDIA: sudo pacman -S nvidia-utils
```

**Void Linux:**
```bash
sudo xbps-install -S ffmpeg libva-utils jq mesa-vaapi-drivers
# Intel: sudo xbps-install -S intel-media-driver
# NVIDIA: sudo xbps-install -S nvidia
```

## Usage

### Basic Syntax
```bash
./cvrt_v7.sh [OPTIONS] [/path/to/directory]
```

### Command-Line Options
- `--replace`, `-r`: Replace original files (⚠️ destructive)
- `--debug`, `-d`: Enable verbose debug output
- `--cpu`: Force software encoding (no artifacts, slower)
- `--gpu`: Auto-select best GPU encoder
- `--nvenc`: Force NVIDIA NVENC
- `--vaapi`: Force AMD/Intel VAAPI  
- `--qsv`: Force Intel Quick Sync Video

### Examples

**Standard conversion (safe):**
```bash
./cvrt_v7.sh /mnt/media/movies
```

**In-place replacement:**
```bash
./cvrt_v7.sh --replace .
```

**Force software encoding (artifact-free):**
```bash
./cvrt_v7.sh --cpu --replace /path/to/videos
```

**Debug hardware detection:**
```bash
./cvrt_v7.sh --debug --vaapi .
```

## Configuration

Edit these variables at the top of the script:

```bash
QUALITY_PARAM=24          # CRF/QP value (20-28 range)
STEREO_BITRATE="192k"     # Audio bitrate for 5.1→stereo
```

### Quality Settings
- `20`: Very high quality, large files
- `24`: Balanced (default)
- `28`: High compression, smaller files

## Hardware-Specific Notes

### AMD APUs/GPUs (VAAPI)
- May produce artifacts with some drivers
- Use `--cpu` flag if quality issues occur
- Fedora: Install `mesa-va-drivers-freeworld` for better support

### Intel iGPUs (QSV)
- Generally reliable quality
- Good performance/quality balance
- Supports 10-bit on newer generations

### NVIDIA GPUs (NVENC)
- Best quality and speed
- RTX 40+ series supports AV1 encoding
- Requires proper driver installation

## Troubleshooting

**No hardware acceleration detected:**
```bash
# Check VAAPI support
vainfo --display drm --device /dev/dri/renderD128

# List available devices
ls /dev/dri/

# Run with debug
./cvrt_v7.sh --debug .
```

**Video artifacts (AMD VAAPI):**
```bash
# Force software encoding
./cvrt_v7.sh --cpu .
```

**Permission issues:**
```bash
# Add user to video group
sudo usermod -a -G video $USER
# Log out and back in
```

## Output

The script provides concise progress updates:
```
🔍 Detecting hardware capabilities...
📊 AMD 12-core | Encoder: VAAPI
   Fallback: SOFTWARE

🎬 Processing 3 .mkv file(s) in: /media/videos

📹 movie1.mkv
   hevc 1920x1080 (10bit) | 2 audio tracks
   🔄 Encoding with VAAPI...
   ✅ Created: movie1-converted.mkv

📊 Results: ✅ 2 successful | ❌ 0 failed | ⏭️ 1 skipped
```

## Safety Features

- **Non-destructive by default**: Creates `-converted.mkv` files
- **Automatic fallbacks**: GPU encoding fails → software encoding
- **RAM disk size checking**: Prevents system hangs
- **Comprehensive validation**: Checks tools and hardware before processing

---

**⚠️ Important:** Always test with a few files before batch processing your entire library. Use `--replace` with caution as it permanently overwrites original files.