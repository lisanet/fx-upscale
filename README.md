# ↕️ fx-upscale
Metal-powered video upscaling

<p align="center">
<img src="https://github.com/finnvoor/fx-upscale/assets/8284016/c2ab0754-13f8-4fcc-a0f1-c10cf727af6d" width="800" />
</p>

> [!TIP]
> Looking for an app-based version of `fx-upscale`? Download [_Unsqueeze_](https://apps.apple.com/app/apple-store/id6475134617?pt=120542042&ct=github&mt=8) today! 🔥

## Usage
```
USAGE: fx-upscale <url> [--width <width>] [--height <height>] [--codec <codec>]

ARGUMENTS:
  <url>                   The video file to upscale

OPTIONS:
  -w, --width <width>         The output file width
  -h, --height <height>       The output file height
  -c, --codec <codec>         Output codec: 'hevc' (default), 'h264', or 'prores'
  -h, --help                  Show help information.
```
- If width and height are specified, they will be used for the output dimensions
- If only 1 of width or height is specified, the other will be inferred proportionally
- If neither width nor height is specified, the video will be upscaled by 2x

> [!NOTE]
> Extremely large outputs are automatically converted to ProRes 422 and saved as `.mov` to ensure stability and compatibility. Specifically, outputs larger than roughly 118 megapixels (≈14.5K × 8.1K) force ProRes due to encoder limitations with H.264/HEVC at those sizes.

## Installation
### Homebrew
```bash
brew install finnvoor/tools/fx-upscale
```

### Mint
```bash
mint install finnvoor/fx-upscale
```

### Manual
Download the latest release from [releases](https://github.com/Finnvoor/MetalFXUpscale/releases).

#### `ffmpeg` upscaling vs `fx-upscale`
<img src="https://github.com/finnvoor/fx-upscale/assets/8284016/7ae867c2-caef-43d8-8fe3-7048c55f55bd" width="800" />
